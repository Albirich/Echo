param(
    [string]$EchoRoot = $env:ECHO_ROOT
)

$SkillOutbox = Join-Path $EchoRoot 'ui\skills.outbox.jsonl'
$SkillInbox  = Join-Path $EchoRoot 'ui\skills.inbox.jsonl'

# --- 1. TARGET THE REAL UI STATE ---
$StateFile = Join-Path $EchoRoot 'ui\state.json'
$DeepMemoryFile = Join-Path $EchoRoot 'memory\deep.json'

if (-not (Test-Path (Split-Path $SkillOutbox))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SkillOutbox) | Out-Null
}
if (-not (Test-Path (Split-Path $SkillInbox))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SkillInbox) | Out-Null
}

function Write-JsonlLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Object
    )
    $line = $Object | ConvertTo-Json -Depth 10 -Compress
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Force -Path $Path | Out-Null
    }
    # Retry logic for writing to outbox
    $retries = 0
    while ($retries -lt 5) {
        try {
            Add-Content -Path $Path -Value $line -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds 50
            $retries++
        }
    }
}

$seenRequestIds = [System.Collections.Generic.HashSet[string]]::new()

function Invoke-Skill {
    param(
        [string]$SkillName,
        [hashtable]$Params
    )

    switch ($SkillName) {
        'memory.search'   { return Invoke-MemorySearch -Params $Params }
        'memory.save'     { return Invoke-MemorySave -Params $Params }
        'memory.forget'   { return Invoke-MemoryForget -Params $Params }
        'room.list_notes' { return Invoke-RoomListNotes -Params $Params }
        'room.delete_note'{ return Invoke-RoomDeleteNote -Params $Params }
        'room.add_note'   { return Invoke-RoomAddNote -Params $Params }
        default {
            return @{ success = $false; error = "Unknown skill '$SkillName'"; data = $null }
        }
    }
}

# --- MEMORY HANDLERS ---------------------------------------------------------

function Get-DeepMemory {
    if (-not (Test-Path $DeepMemoryFile)) { return @() }
    try {
        $raw = Get-Content -Raw -Path $DeepMemoryFile -ErrorAction Stop
        if (-not $raw.Trim()) { return @() }
        return $raw | ConvertFrom-Json
    } catch {
        return @()
    }
}

function Save-DeepMemory($items) {
    try {
        $items | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $DeepMemoryFile
    } catch {
        Write-Host "[Error] Failed to save deep memory: $($_.Exception.Message)"
    }
}

function Invoke-MemorySearch {
    param([hashtable]$Params)
    $tag = $Params.tag
    $limit = if ($Params.limit) { [int]$Params.limit } else { 20 }

    $items = @(Get-DeepMemory)
    if ($tag) {
        $items = $items | Where-Object { $_.tags -contains $tag }
    }
    $items = $items | Select-Object -First $limit

    return @{ success = $true; error = $null; data = @{ matches = $items } }
}

function Invoke-MemorySave {
    param([hashtable]$Params)
    $k = $Params.k; $v = $Params.v
    if (-not $k) { return @{ success=$false; error="memory.save missing 'k'" } }

    $items = @(Get-DeepMemory)
    $existing = $items | Where-Object { $_.key -eq $k }
    $others   = $items | Where-Object { $_.key -ne $k }

    $new = [pscustomobject]@{ key = $k; value = $v }
    $all = @($others + $new)
    Save-DeepMemory -items $all

    return @{ success=$true; data=@{ key=$k } }
}

function Invoke-MemoryForget {
    param([hashtable]$Params)
    $k = $Params.k
    if (-not $k) { return @{ success=$false; error="memory.forget missing 'k'" } }

    $items = @(Get-DeepMemory)
    $before = $items.Count
    $items = $items | Where-Object { $_.key -ne $k }
    $after = $items.Count
    Save-DeepMemory -items $items

    return @{ success=$true; data=@{ removed=($before - $after) } }
}

# --- ROOM HANDLERS (With Retry Logic) ----------------------------------------

function Get-StateJson {
    $retries = 0
    while ($retries -lt 5) {
        try {
            if (-not (Test-Path $StateFile)) { return $null }
            # -Shared Read to allow UI to have it open
            $fs = [System.IO.File]::Open($StateFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $raw = $sr.ReadToEnd()
            $sr.Close()
            $fs.Close()

            if (-not $raw.Trim()) { return $null }
            return $raw | ConvertFrom-Json
        } catch {
            Start-Sleep -Milliseconds 100
            $retries++
        }
    }
    return $null
}

function Save-StateJson($jsonObj) {
    $retries = 0
    while ($retries -lt 5) {
        try {
            $json = $jsonObj | ConvertTo-Json -Depth 10
            # Force UTF8 no BOM
            [System.IO.File]::WriteAllText($StateFile, $json, [System.Text.Encoding]::UTF8)
            break
        } catch {
            Start-Sleep -Milliseconds 100
            $retries++
        }
    }
}

function Get-RoomNotes {
    $state = Get-StateJson
    if (-not $state) { return @() }
    
    # --- CRITICAL FIX: Look for 'widgets' first (what UI uses) ---
    if ($state.widgets) { return @($state.widgets) }
    if ($state.notes)   { return @($state.notes) }
    return @()
}

function Save-RoomNotes($items) {
    $state = Get-StateJson
    if (-not $state) { return }

    # Update the correct property
    if ($state.PSObject.Properties.Name -contains 'widgets') {
        $state.widgets = $items
    } elseif ($state.PSObject.Properties.Name -contains 'notes') {
        $state.notes = $items
    } else {
        # Default to widgets if neither exists
        $state | Add-Member -NotePropertyName 'widgets' -NotePropertyValue $items
    }
    Save-StateJson $state
}

function Invoke-RoomListNotes {
    param([hashtable]$Params)
    $notes = Get-RoomNotes
    return @{ success = $true; data = @{ notes = $notes } }
}

function Invoke-RoomAddNote {
    param([hashtable]$Params)
    $text = $Params.text
    if (-not $text) { return @{ success=$false; error="room.add_note missing 'text'" } }

    $notes = Get-RoomNotes
    $id = [guid]::NewGuid().ToString()
    
    # Create valid widget structure
    $note = [pscustomobject]@{
        id    = $id
        text  = $text
        x     = 100
        y     = 150
        color = "#69f" # Default blue
    }

    $all = @($notes + $note)
    Save-RoomNotes -items $all

    return @{ success = $true; data = @{ note = $note } }
}

function Invoke-RoomDeleteNote {
    param([hashtable]$Params)
    $id = $Params.id
    if (-not $id) { return @{ success=$false; error="room.delete_note missing 'id'" } }

    $notes = Get-RoomNotes
    $before = $notes.Count
    
    # Filter
    $remaining = $notes | Where-Object { $_.id -ne $id }
    $after = $remaining.Count

    Save-RoomNotes -items $remaining

    return @{ success = $true; data = @{ removed = ($before - $after); id = $id } }
}

# --- Main loop ---------------------------------------------------------------

Write-Host "[SkillsLoop] Starting. Reading from: $StateFile"

$lastLineCount = 0

while ($true) {
    if (Test-Path $SkillOutbox) {
        # Use retry-read for the outbox too
        $lines = $null
        try {
            $fs = [System.IO.File]::Open($SkillOutbox, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $fileContent = $sr.ReadToEnd()
            $sr.Close(); $fs.Close()
            $lines = $fileContent -split "`r`n"
        } catch {
            Start-Sleep -Milliseconds 100
            continue
        }

        if ($lines) {
            for ($i = $lastLineCount; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if (-not $line.Trim()) { continue }

                try { $obj = $line | ConvertFrom-Json } catch { continue }
                if ($obj.type -ne 'skill_request') { continue }

                $reqId = $obj.request_id
                if ($seenRequestIds.Contains($reqId)) { continue }
                [void]$seenRequestIds.Add($reqId)

                Write-Host "Executing skill: $($obj.skill)" -ForegroundColor Cyan

                $skillName = $obj.skill
                $params    = @{}
                if ($obj.params) {
                    foreach ($p in $obj.params.PSObject.Properties) {
                        $params[$p.Name] = $p.Value
                    }
                }

                $result = Invoke-Skill -SkillName $skillName -Params $params

                $response = @{
                    type       = "skill_response"
                    request_id = $reqId
                    success    = $result.success
                    error      = $result.error
                    data       = $result.data
                    created_at = (Get-Date).ToString("o")
                    skill      = $skillName
                    step_id    = $obj.step_id
                    loop_id    = $obj.loop_id
                }

                Write-JsonlLine -Path $SkillInbox -Object $response
            }
            $lastLineCount = $lines.Count
        }
    }
    Start-Sleep -Milliseconds 200
}