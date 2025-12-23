param(
    [int]$PollMs = 250
)

$ErrorActionPreference = 'Stop'

# -------------------------------
# Root / env bootstrapping
# -------------------------------
$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $env:ECHO_ROOT) {
    if ($env:ECHO_HOME) {
        $env:ECHO_ROOT = $env:ECHO_HOME
    } else {
        # Assume scripts\SkillRuntime.ps1 -> root is parent folder
        $env:ECHO_ROOT = Split-Path -Parent $script:ScriptRoot
    }
}

$Root = $env:ECHO_ROOT

# -------------------------------
# Paths
# -------------------------------
$SkillDir    = Join-Path $Root 'ui'
$SkillOutbox = Join-Path $SkillDir 'skills.outbox.jsonl'
$SkillInbox  = Join-Path $SkillDir 'skills.inbox.jsonl'
$StateFile   = Join-Path $Root 'ui\state.json'
$OutboxCursorPath = Join-Path $Root 'state\skills.outbox.cursor'

if (-not (Test-Path $SkillDir)) {
    New-Item -ItemType Directory -Force -Path $SkillDir | Out-Null
}

$LogDir      = Join-Path $Root 'logs'
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
}
$SkillsLog   = Join-Path $LogDir 'skills.runtime.log.jsonl'

$DeepMemPathJson  = Join-Path $Root 'memory\deep.json'
$DeepMemPathJsonl = Join-Path $Root 'memory\deep.jsonl'
$ThinkingInfoFile = Join-Path $Root 'state\ThinkingInfo.json'

# Ephemeral note store (for planner testing).
# You can later swap this to your real notes backend.
$script:Notes = @()

# -------------------------------
# Helpers
# -------------------------------
function Log-Json {
    param(
        [string]$Event,
        [hashtable]$Data
    )

    $obj = @{
        ts    = (Get-Date).ToString('o')
        event = $Event
        data  = $Data
    }

    $line = $obj | ConvertTo-Json -Depth 10 -Compress
    if (-not (Test-Path $SkillsLog)) {
        New-Item -ItemType File -Force -Path $SkillsLog | Out-Null
    }
    Add-Content -Path $SkillsLog -Value $line
}

function Write-JsonlLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Object
    )

    $line = $Object | ConvertTo-Json -Depth 10 -Compress
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Force -Path $Path | Out-Null
    }
    Add-Content -Path $Path -Value $line
}

function Load-OutboxCursor {
    if (-not (Test-Path $OutboxCursorPath)) {
        return @{ line = 0; length = 0 }
    }
    try {
        $raw = Get-Content -Raw -Path $OutboxCursorPath -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        return @{
            line   = [int]$obj.line
            length = [long]$obj.length
        }
    } catch {
        return @{ line = 0; length = 0 }
    }
}

function Save-OutboxCursor {
    param([int]$Line, [long]$Length)
    $dir = Split-Path -Parent $OutboxCursorPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    @{ line = $Line; length = $Length } |
        ConvertTo-Json -Compress |
        Set-Content -Encoding UTF8 -Path $OutboxCursorPath
}

function Load-DeepMemory {
    $items = @()

    if (Test-Path $DeepMemPathJsonl) {
        try {
            $lines = Get-Content -Path $DeepMemPathJsonl -ErrorAction Stop
            foreach ($line in $lines) {
                if (-not $line.Trim()) { continue }
                try { $items += ($line | ConvertFrom-Json) } catch {}
            }
        } catch {
            Log-Json -Event 'deep_memory_parse_error' -Data @{
                error = $_.Exception.Message
                path  = $DeepMemPathJsonl
            }
        }
    }
    elseif (Test-Path $DeepMemPathJson) {
        try {
            $raw = Get-Content -Raw -Path $DeepMemPathJson -ErrorAction Stop | ConvertFrom-Json
            $items += @($raw)
        } catch {
            Log-Json -Event 'deep_memory_parse_error' -Data @{
                error = $_.Exception.Message
                path  = $DeepMemPathJson
            }
        }
    }

    return $items
}

function Save-DeepMemory {
    param(
        [object[]]$Items
    )

    $dir  = Split-Path -Parent $DeepMemPathJsonl
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    if (Test-Path $DeepMemPathJsonl) {
        $lines = @()
        foreach ($item in $Items) { $lines += ($item | ConvertTo-Json -Depth 10 -Compress) }
        Set-Content -Encoding UTF8 -Path $DeepMemPathJsonl -Value $lines
    }
    else {
        $json = $Items | ConvertTo-Json -Depth 10
        $json | Set-Content -Encoding UTF8 -Path $DeepMemPathJson
    }
}

function Write-SideChannel {
    param(
        [string]$Source,
        [object]$Data
    )

    try {
        $dir = Split-Path -Parent $ThinkingInfoFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $payload = @{ source = $Source; ts = (Get-Date).ToString("o"); data = $Data }
        $json = $payload | ConvertTo-Json -Depth 10
        Set-Content -Path $ThinkingInfoFile -Value $json -Force
    } catch {
        Log-Json -Event 'sidechannel_error' -Data @{ source = $Source; error = $_.Exception.Message }
    }
}

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
        } catch {
            Start-Sleep -Milliseconds 50
            $retries++
        }
    }
    return $null
}

function Save-StateJson {
    param([object]$JsonObj)
    $dir = Split-Path -Parent $StateFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $JsonObj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StateFile, $json, [System.Text.Encoding]::UTF8)
}

# -------------------------------
# Tool implementations
# -------------------------------

function Invoke-MemorySearch {
    param(
        [pscustomobject]$Params
    )

    $tag   = $Params.tag
    $limit = if ($Params.PSObject.Properties.Name -contains 'limit') {
        [int]$Params.limit
    } else { 10 }

    $items   = Load-DeepMemory
    $matches = @()

    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $tags = @($item.tags)
        if ($tag -and ($tags -contains $tag)) {
            $matches += $item
            if ($matches.Count -ge $limit) { break }
        }
    }

    Write-SideChannel -Source 'memory.search' -Data $matches

    return @{
        matches = $matches
    }
}

function Invoke-MemorySave {
    param(
        [pscustomobject]$Params
    )

    $k    = $Params.k
    $v    = $Params.v
    $tags = @()

    if ($Params.PSObject.Properties.Name -contains 'tags') {
        $tags = @($Params.tags)
    }

    $items = Load-DeepMemory

    # Upsert by key if present; otherwise append.
    $existing = $items | Where-Object { $_.k -eq $k }
    if ($existing) {
        foreach ($e in $existing) {
            $e.v    = $v
            $e.tags = $tags
        }
    } else {
        $items += [pscustomobject]@{
            k    = $k
            v    = $v
            tags = $tags
        }
    }

    Save-DeepMemory -Items $items

    return @{
        saved = $true
        key   = $k
    }
}

function Invoke-MemoryForget {
    param(
        [pscustomobject]$Params
    )

    $k = $Params.k
    $items = Load-DeepMemory
    $before = $items.Count

    $items = $items | Where-Object { $_.k -ne $k }
    $after = $items.Count

    Save-DeepMemory -Items $items

    return @{
        deleted_count = ($before - $after)
        key           = $k
    }
}

# ----------------- Room / Notes (ephemeral) ----------------------------------

function Invoke-RoomAddNote {
    param(
        [pscustomobject]$Params
    )

    $id = [guid]::NewGuid().ToString()
    $note = [pscustomobject]@{
        id         = $id
        text       = $Params.text
        x          = if ($Params.PSObject.Properties.Name -contains 'x') { $Params.x } else { $null }
        y          = if ($Params.PSObject.Properties.Name -contains 'y') { $Params.y } else { $null }
        color      = if ($Params.PSObject.Properties.Name -contains 'color') { $Params.color } else { $null }
        created_at = (Get-Date).ToString('o')
    }

    $state = Get-StateJson
    if (-not $state) { $state = [pscustomobject]@{} }

    $items = @()
    $target = $null
    if ($state.PSObject.Properties.Name -contains 'widgets' -and $state.widgets) {
        $items += @($state.widgets)
        $target = 'widgets'
    }
    elseif ($state.PSObject.Properties.Name -contains 'notes' -and $state.notes) {
        $items += @($state.notes)
        $target = 'notes'
    }
    else {
        $target = 'widgets'
    }

    # Ensure we keep an array shape even with a single item
    $list = [System.Collections.ArrayList]::new()
    foreach ($i in $items) { [void]$list.Add($i) }
    [void]$list.Add($note)

    if ($state.PSObject.Properties.Name -contains $target) { $state.$target = $list }
    else { $state | Add-Member -MemberType NoteProperty -Name $target -Value $list -Force }

    Save-StateJson $state

    return @{
        note = $note
    }
}

function Invoke-RoomListNotes {
    param(
        [pscustomobject]$Params
    )

    $state = Get-StateJson
    $notes = @()
    if ($state -and $state.widgets) { $notes += @($state.widgets) }
    elseif ($state -and $state.notes) { $notes += @($state.notes) }

    Write-SideChannel -Source 'room.list_notes' -Data $notes

    return @{ notes = $notes }
}

function Invoke-RoomDeleteNote {
    param(
        [pscustomobject]$Params
    )

    $id = $Params.id
    $state = Get-StateJson
    $items = @()
    $target = $null
    if ($state -and $state.widgets) { $items += @($state.widgets); $target = 'widgets' }
    elseif ($state -and $state.notes) { $items += @($state.notes); $target = 'notes' }

    $before = $items.Count
    $remaining = $items | Where-Object { $_.id -ne $id }
    if ($target) {
        $list = [System.Collections.ArrayList]::new()
        foreach ($r in $remaining) { [void]$list.Add($r) }
        if ($state.PSObject.Properties.Name -contains $target) { $state.$target = $list }
        else { $state | Add-Member -MemberType NoteProperty -Name $target -Value $list -Force }
        Save-StateJson $state
    }
    $after = $remaining.Count

    return @{
        deleted      = ($before - $after) -gt 0
        id           = $id
        deleted_count = ($before - $after)
    }
}

function Invoke-RoomSetBackground {
    param(
        [pscustomobject]$Params
    )

    # For now: just acknowledge. Your real Room process can listen to its own bus.
    return @{
        src       = $Params.src
        accepted  = $true
        message   = "Background change acknowledged by SkillRuntime."
    }
}

# -------------------------------
# Dispatcher
# -------------------------------
function Handle-SkillRequest {
    param(
        [pscustomobject]$Req
    )

    $skill = [string]$Req.skill
    $params = [pscustomobject]$Req.params
    
    # Define root for local file operations inside skills
    $Root = if ($env:ECHO_ROOT) { $env:ECHO_ROOT } else { "D:\Echo" }

    try {
        switch ($skill) {
            # --- EXISTING SKILLS ---
            'memory.search'      { $data = Invoke-MemorySearch      -Params $params }
            'memory.save'        { $data = Invoke-MemorySave        -Params $params }
            'memory.forget'      { $data = Invoke-MemoryForget      -Params $params }
            'room.add_note'      { $data = Invoke-RoomAddNote       -Params $params }
            'room.list_notes'    { $data = Invoke-RoomListNotes     -Params $params }
            'room.delete_note'   { $data = Invoke-RoomDeleteNote    -Params $params }
            'room.set_background'{ $data = Invoke-RoomSetBackground -Params $params }

            # --- NEW DISCORD SKILLS ---
            
            'social.lookup_user' {
                $name = $params.name
                if (-not $name) { throw "Missing 'name' parameter." }
                
                $pPath = Join-Path $Root "ui\user_profiles.json"
                if (-not (Test-Path $pPath)) { throw "No user profiles found." }
                
                $all = Get-Content $pPath -Raw | ConvertFrom-Json
                $matches = @()
                
                # Iterate through profile objects
                foreach ($prop in $all.PSObject.Properties) {
                    $u = $prop.Value
                    # Match Name OR Nickname
                    if ($u.name -match $name -or ($u.nicknames -and ($u.nicknames -match $name))) {
                        $matches += @{ 
                            id = $u.id
                            name = $u.name
                            last_session_id = $u.last_session_id
                            affinity = $u.affinity
                        }
                    }
                }
                
                if ($matches.Count -eq 0) { throw "No user found matching '$name'." }
                $data = $matches
            }

            'discord.send' {
                $txt = $params.text
                $tgt = $params.target_id
                
                # If target not provided, try to find "last active discord session"
                if (-not $tgt) {
                    $sPath = Join-Path $Root "ui\state.json"
                    if (Test-Path $sPath) {
                        $st = Get-Content $sPath -Raw | ConvertFrom-Json
                        $tgt = $st.last_discord_session
                    }
                }
                
                if (-not $txt) { throw "Missing 'text' parameter." }
                if (-not $tgt) { throw "Missing 'target_id' and no last active session found." }

                $payload = @{
                    source = "echo"
                    session_id = $tgt
                    text = $txt
                    ts = (Get-Date).ToString("o")
                }
                
                # Write to Outbox
                $outPath = Join-Path $Root "ui\outbox_discord"
                if (-not (Test-Path $outPath)) { New-Item -ItemType Directory -Force -Path $outPath | Out-Null }
                
                $fName = (Get-Date).Ticks.ToString() + ".json"
                $payload | ConvertTo-Json | Set-Content (Join-Path $outPath $fName)
                
                $data = "Message queued for Discord (Target: $tgt)"
            }

            default {
                throw "Unknown skill '$skill'"
            }
        }

        # --- RESPONSE HANDLING (Unchanged) ---
        $resp = @{
            type       = 'skill_response'
            request_id = $Req.request_id
            loop_id    = $Req.loop_id
            step_id    = $Req.step_id
            skill      = $skill
            success    = $true
            error      = $null
            data       = $data
            ts         = (Get-Date).ToString('o')
        }

        Write-JsonlLine -Path $SkillInbox -Object $resp
        Log-Json -Event 'skill_success' -Data @{ request_id = $Req.request_id; skill = $skill }
    }
    catch {
        $err = $_.Exception.Message
        $resp = @{
            type       = 'skill_response'
            request_id = $Req.request_id
            loop_id    = $Req.loop_id
            step_id    = $Req.step_id
            skill      = $skill
            success    = $false
            error      = $err
            data       = $null
            ts         = (Get-Date).ToString('o')
        }

        Write-JsonlLine -Path $SkillInbox -Object $resp
        Log-Json -Event 'skill_error' -Data @{ request_id = $Req.request_id; skill = $skill; error = $err }
    }
}

# -------------------------------
# Main loop
# -------------------------------
Write-Host "[SkillRuntime] Starting. ROOT=$Root"
Write-Host "[SkillRuntime] Outbox: $SkillOutbox"
Write-Host "[SkillRuntime] Inbox : $SkillInbox"

# Track which request_ids we've already processed
$processed = New-Object System.Collections.Generic.HashSet[string]
$cursor = Load-OutboxCursor
$lastProcessedLine = [int]$cursor.line
$lastOutboxLength  = [long]$cursor.length

while ($true) {
    try {
        if (Test-Path $SkillOutbox) {
            $outboxStat = Get-Item -LiteralPath $SkillOutbox -ErrorAction SilentlyContinue
            $lines = Get-Content -Path $SkillOutbox -ErrorAction SilentlyContinue
            if (-not $lines) { $lines = @() }

            # Reset cursor if file was truncated/rotated
            if (($outboxStat -and $outboxStat.Length -lt $lastOutboxLength) -or ($lines.Count -lt $lastProcessedLine)) {
                $lastProcessedLine = 0
                $processed.Clear()
            }

            for ($i = $lastProcessedLine; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if (-not $line.Trim()) { continue }

                try {
                    $obj = $line | ConvertFrom-Json
                } catch {
                    Log-Json -Event 'outbox_parse_error' -Data @{ line = $line; error = $_.Exception.Message }
                    continue
                }

                if ($obj.type -ne 'skill_request') { continue }
                $reqId = [string]$obj.request_id
                if (-not $reqId) { continue }

                if ($processed.Contains($reqId)) { continue }
                $processed.Add($reqId) | Out-Null

                Handle-SkillRequest -Req $obj
            }

            $lastProcessedLine = $lines.Count
            $lastOutboxLength  = if ($outboxStat) { [long]$outboxStat.Length } else { 0 }
            Save-OutboxCursor -Line $lastProcessedLine -Length $lastOutboxLength
        }
    } catch {
        Log-Json -Event 'runtime_loop_error' -Data @{ error = $_.Exception.Message }
    }

    Start-Sleep -Milliseconds $PollMs
}
