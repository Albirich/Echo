param(
    [string]$EchoRoot = $env:ECHO_ROOT
)

# --- DEBUG PATHS ---
Write-Host "================ SKILLS LOOP DEBUG ================" -ForegroundColor Magenta
if (-not $EchoRoot) {
    $EchoRoot = $PSScriptRoot
    Write-Host "Root missing. Defaulting to: $EchoRoot" -ForegroundColor Red
}

$SkillOutbox = Join-Path $EchoRoot 'ui\skills.outbox.jsonl'
$SkillInbox  = Join-Path $EchoRoot 'ui\skills.inbox.jsonl'
$StateFile   = Join-Path $EchoRoot 'ui\state.json'
$DeepMemFile = Join-Path $EchoRoot 'memory\deep.json'
$ThinkingInfoFile = Join-Path $EchoRoot 'state\ThinkingInfo.json' 

# --- DIRS ---
if (-not (Test-Path (Split-Path $SkillOutbox))) { New-Item -ItemType Directory -Force -Path (Split-Path $SkillOutbox) | Out-Null }
if (-not (Test-Path (Split-Path $SkillInbox)))  { New-Item -ItemType Directory -Force -Path (Split-Path $SkillInbox) | Out-Null }

# --- HELPERS ---
function Write-JsonlLine {
    param([string]$Path, [hashtable]$Object)
    $line = $Object | ConvertTo-Json -Depth 10 -Compress
    $retries = 0
    while ($retries -lt 5) {
        try { Add-Content -Path $Path -Value $line -ErrorAction Stop; break }
        catch { Start-Sleep -Milliseconds 50; $retries++ }
    }
}

function Write-SideChannel {
    param([string]$Source, [object]$Data)
    try {
        $dir = Split-Path $ThinkingInfoFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $info = @{ source = $Source; ts = (Get-Date).ToString("o"); data = $Data }
        $json = $info | ConvertTo-Json -Depth 10
        Set-Content -Path $ThinkingInfoFile -Value $json -Force
        Write-Host "[SideChannel] Wrote $Source data to ThinkingInfo.json" -ForegroundColor Yellow
    } catch {
        Write-Host "[SideChannel] Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$seenRequestIds = [System.Collections.Generic.HashSet[string]]::new()

# --- STATE HANDLERS ---
function Get-StateJson {
    if (-not (Test-Path $StateFile)) { return $null }
    $retries = 0
    while ($retries -lt 5) {
        try {
            $fs = [System.IO.File]::Open($StateFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $raw = $sr.ReadToEnd()
            $sr.Close(); $fs.Close()
            if (-not $raw.Trim()) { return $null }
            return $raw | ConvertFrom-Json
        } catch { Start-Sleep -Milliseconds 50; $retries++ }
    }
    return $null
}

function Save-StateJson($jsonObj) {
    $json = $jsonObj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StateFile, $json, [System.Text.Encoding]::UTF8)
}

function Get-DeepMemory {
    if (-not (Test-Path $DeepMemFile)) { return @() }
    try {
        $raw = Get-Content -Raw -Path $DeepMemFile -ErrorAction Stop
        if (-not $raw.Trim()) { return @() }
        return $raw | ConvertFrom-Json
    } catch { return @() }
}

function Save-DeepMemory($items) {
    $items | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $DeepMemFile
}

# --- TOOLS ---
function Invoke-MemorySearch {
    param([hashtable]$Params)
    $tag = $Params.tag
    $limit = if ($Params.limit) { [int]$Params.limit } else { 20 }
    $items = @(Get-DeepMemory)
    if ($tag) { $items = $items | Where-Object { ($_.k -like "*$tag*") -or ($_.v -like "*$tag*") } }
    $items = $items | Select-Object -First $limit
    Write-SideChannel -Source "memory.search" -Data $items
    return @{ success=$true; data=@{ matches=$items } }
}

function Invoke-RoomListNotes {
    param([hashtable]$Params)
    $state = Get-StateJson
    $notes = @()
    # Explicitly prioritize widgets
    if ($state -and $state.widgets) { $notes = @($state.widgets) }
    elseif ($state -and $state.notes) { $notes = @($state.notes) }
    
    Write-SideChannel -Source "room.list_notes" -Data $notes
    return @{ success=$true; data=@{ notes=$notes } }
}

function Invoke-RoomDeleteNote {
    param([hashtable]$Params)
    $id = $Params.id
    if (-not $id) { return @{ success=$false; error="Missing 'id'" } }
    $state = Get-StateJson
    
    # Use ArrayList to safely handle list manipulation
    $list = [System.Collections.ArrayList]::new()
    $items = if ($state.widgets) { @($state.widgets) } else { @($state.notes) }
    $target = if ($state.widgets) { "widgets" } else { "notes" }
    
    $found = 0
    foreach ($item in $items) {
        if ($item.id -eq $id) { $found++ }
        else { [void]$list.Add($item) }
    }
    
    if ($target -eq "widgets") { $state.widgets = $list } else { $state.notes = $list }
    
    Save-StateJson $state
    return @{ success=$true; data=@{ removed=$found; id=$id } }
}

function Invoke-RoomAddNote {
    param([hashtable]$Params)
    $text = $Params.text
    if (-not $text) { return @{ success=$false; error="Missing 'text'" } }

    $state = Get-StateJson
    if (-not $state) { return @{ success=$false; error="Cannot read state file" } }

    # Ensure widgets array exists
    if (-not $state.PSObject.Properties.Name.Contains('widgets')) {
        $state | Add-Member -MemberType NoteProperty -Name 'widgets' -Value @() -Force
    }

    # Safe List Construction
    $list = [System.Collections.ArrayList]::new()
    if ($state.widgets) {
        foreach ($w in $state.widgets) { [void]$list.Add($w) }
    }

    $id = [guid]::NewGuid().ToString()
    $note = @{
        id    = $id
        text  = $text
        x     = if ($Params.x) { $Params.x } else { 220 }
        y     = if ($Params.y) { $Params.y } else { 200 }
        color = if ($Params.color) { $Params.color } else { "#69f" }
    }

    [void]$list.Add($note)
    $state.widgets = $list
    Save-StateJson $state

    return @{ success=$true; data=@{ note=$note } }
}

# --- DISPATCHER ---
function Invoke-Skill {
    param([string]$SkillName, [hashtable]$Params)
    switch ($SkillName) {
        'room.list_notes'  { return Invoke-RoomListNotes -Params $Params }
        'room.delete_note' { return Invoke-RoomDeleteNote -Params $Params }
        'room.add_note'    { return Invoke-RoomAddNote -Params $Params }
        'memory.search'    { return Invoke-MemorySearch -Params $Params }
        default { return @{ success=$true; data="Simulated success for $SkillName" } }
    }
}

# --- LOOP ---
Write-Host "SkillsLoop Running..." -ForegroundColor Cyan
$lastLineCount = 0
while ($true) {
    if (Test-Path $SkillOutbox) {
        $lines = $null
        try {
            $fs = [System.IO.File]::Open($SkillOutbox, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs); $raw = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            $lines = $raw -split "`r`n"
        } catch {}

        if ($lines) {
            for ($i = $lastLineCount; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if (-not $line.Trim()) { continue }
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                if ($obj.type -ne 'skill_request') { continue }
                $reqId = $obj.request_id
                if ($seenRequestIds.Contains($reqId)) { continue }
                [void]$seenRequestIds.Add($reqId)

                Write-Host "Exec: $($obj.skill)" -ForegroundColor Yellow
                $res = Invoke-Skill -SkillName $obj.skill -Params $obj.params
                
                $response = @{ type="skill_response"; request_id=$reqId; success=$res.success; error=$res.error; data=$res.data; skill=$obj.skill }
                Write-JsonlLine -Path $SkillInbox -Object $response
            }
            $lastLineCount = $lines.Count
        }
    }
    Start-Sleep -Milliseconds 200
}