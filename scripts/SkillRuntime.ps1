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

if (-not (Test-Path $SkillDir)) {
    New-Item -ItemType Directory -Force -Path $SkillDir | Out-Null
}

$LogDir      = Join-Path $Root 'logs'
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
}
$SkillsLog   = Join-Path $LogDir 'skills.runtime.log.jsonl'

$DeepMemPath = Join-Path $Root 'memory\deep.json'

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

function Load-DeepMemory {
    if (-not (Test-Path $DeepMemPath)) {
        return @()
    }

    try {
        $raw = Get-Content -Raw -Path $DeepMemPath | ConvertFrom-Json
        return @($raw)
    } catch {
        Log-Json -Event 'deep_memory_parse_error' -Data @{
            error = $_.Exception.Message
            path  = $DeepMemPath
        }
        return @()
    }
}

function Save-DeepMemory {
    param(
        [object[]]$Items
    )

    $json = $Items | ConvertTo-Json -Depth 10
    $dir  = Split-Path -Parent $DeepMemPath
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $json | Set-Content -Encoding UTF8 -Path $DeepMemPath
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

    $script:Notes += $note

    return @{
        note = $note
    }
}

function Invoke-RoomListNotes {
    param(
        [pscustomobject]$Params
    )

    return @{
        notes = $script:Notes
    }
}

function Invoke-RoomDeleteNote {
    param(
        [pscustomobject]$Params
    )

    $id = $Params.id
    $before = $script:Notes.Count
    $script:Notes = $script:Notes | Where-Object { $_.id -ne $id }
    $after = $script:Notes.Count

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

    try {
        switch ($skill) {
            'memory.search'      { $data = Invoke-MemorySearch      -Params $params }
            'memory.save'        { $data = Invoke-MemorySave        -Params $params }
            'memory.forget'      { $data = Invoke-MemoryForget      -Params $params }
            'room.add_note'      { $data = Invoke-RoomAddNote       -Params $params }
            'room.list_notes'    { $data = Invoke-RoomListNotes     -Params $params }
            'room.delete_note'   { $data = Invoke-RoomDeleteNote    -Params $params }
            'room.set_background'{ $data = Invoke-RoomSetBackground -Params $params }
            default {
                throw "Unknown skill '$skill'"
            }
        }

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
        Log-Json -Event 'skill_success' -Data @{
            request_id = $Req.request_id
            skill      = $skill
        }
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
        Log-Json -Event 'skill_error' -Data @{
            request_id = $Req.request_id
            skill      = $skill
            error      = $err
        }
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

while ($true) {
    try {
        if (Test-Path $SkillOutbox) {
            $lines = Get-Content -Path $SkillOutbox -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
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
        }
    } catch {
        Log-Json -Event 'runtime_loop_error' -Data @{ error = $_.Exception.Message }
    }

    Start-Sleep -Milliseconds $PollMs
}
