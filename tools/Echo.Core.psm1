# Echo.Core.psm1 - shared helpers for Echo stack (PS 5.1-safe)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

function Get-EchoHome {
    param([string]$Hint)
    if ($env:ECHO_HOME -and (Test-Path -LiteralPath $env:ECHO_HOME)) { return $env:ECHO_HOME }
    if ($Hint -and (Test-Path -LiteralPath $Hint)) { return $Hint }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

function Get-EchoPaths {
    param([string]$EchoHome)
    $echoHome = Get-EchoHome $EchoHome
    return [pscustomobject]@{
        Home                = $echoHome
        Logs                = Join-Path $echoHome 'logs'
        State               = Join-Path $echoHome 'state'
        UI                  = Join-Path $echoHome 'ui'
        Inbox               = Join-Path $echoHome 'ui\inboxq'
        Outbox              = Join-Path $echoHome 'ui\outbox.jsonl'
        WakePings           = Join-Path $echoHome 'state\wakeup.pings.jsonl'
        Context             = Join-Path $echoHome 'state\context.json'
        ContextHistory      = Join-Path $echoHome 'state\context_history.jsonl'
        ConversationHistory = Join-Path $echoHome 'state\conversation_history.jsonl'
        Emotion             = Join-Path $echoHome 'state\emotion.vad.json'
        Thoughts            = Join-Path $echoHome 'state\im.thoughts.jsonl'
        Wakeup              = Join-Path $echoHome 'state\wakeup.json'
        Diary               = Join-Path $echoHome 'diary'
        Schedule            = Join-Path $echoHome 'data\schedule.json'
        Stand               = Join-Path $echoHome 'stand'
        Models              = Join-Path $echoHome 'models'
        LastAvatar          = Join-Path $echoHome 'state\last_avatar.json'
        ScreenCaptionHistory = Join-Path $echoHome 'state\screen.caption.history.json'
        Preferences         = Join-Path $echoHome 'state\preferences.json'    
        DeepMemory          = Join-Path $echoHome 'memory\deep.jsonl'
        Voice_Outbox        = Join-Path $echoHome 'ui\outbox_voice'
        voice_inbox         = Join-Path $echoHome 'ui\inbox_voice'
    }
}

function Ensure-EchoPaths {
    param($Paths)
    $dirs = @($Paths.Logs, $Paths.State, $Paths.UI, $Paths.Inbox)
    foreach ($d in $dirs) {
        if ($d -and -not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
    if ($Paths.Outbox -and -not (Test-Path -LiteralPath $Paths.Outbox)) {
        '' | Set-Content -LiteralPath $Paths.Outbox -Encoding UTF8 -NoNewline
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-JsonFile {
    param([string]$Path, [object]$Data, [switch]$Compress, [int]$Depth = 20)
    $json = if ($Compress) { $Data | ConvertTo-Json -Depth $Depth -Compress } else { $Data | ConvertTo-Json -Depth $Depth }
    [System.IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Append-Jsonl {
    param([string]$Path, [object]$Data, [switch]$EnsureDir)
    if ($EnsureDir) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    $line = $Data | ConvertTo-Json -Depth 20 -Compress
    $sw = New-Object IO.StreamWriter($Path, $true, [Text.UTF8Encoding]::new($false))
    try { $sw.WriteLine($line) } finally { $sw.Dispose() }
}

function Write-LogLine {
    param(
        [string]$Component,
        [string]$Kind,
        [object]$Data,
        [string]$LogRoot
    )
    $logDir = $LogRoot
    if (-not $logDir) { $logDir = '.' }
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $label = if ($Component -and $Component.Trim().Length -gt 0) { $Component } else { 'echo' }
    $file = Join-Path $logDir ($label + '.events.jsonl')
    $entry = @{
        ts   = (Get-Date).ToString('o')
        kind = $Kind
        data = $Data
    }
    Append-Jsonl -Path $file -Data $entry
}

function Test-SimilarPing {
    param([string]$NewPing, [array]$RecentPings)
    if (-not $NewPing -or -not $NewPing.Trim()) { return $false }
    $new = $NewPing.Trim().ToLower()
    foreach ($recent in $RecentPings) {
        if (-not $recent) { continue }
        $old = $recent.Trim().ToLower()
        # Check for exact match
        if ($new -eq $old) { return $true }
        # Check for very similar (same key words)
        $newWords = $new -split '\s+' | Where-Object { $_.Length -gt 3 }
        $oldWords = $old -split '\s+' | Where-Object { $_.Length -gt 3 }
        if ($newWords -and $oldWords) {
            $matchCount = 0
            foreach ($nw in $newWords) {
                foreach ($ow in $oldWords) {
                    if ($nw -eq $ow) { $matchCount++ }
                }
            }
            # If more than 60% of significant words match, it's too similar
            $similarity = $matchCount / [Math]::Max($newWords.Count, $oldWords.Count)
            if ($similarity -gt 0.6) { return $true }
        }
    }
    return $false
}

function Load-DiaryEntries {
    param($Paths, [int]$Count = 10)
    $entries = @()
    if (-not (Test-Path -LiteralPath $Paths.Diary)) { return $entries }
    $files = Get-ChildItem -LiteralPath $Paths.Diary -Filter '*.md' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First $Count
    foreach ($f in $files) {
        $text = ''
        try { $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 } catch {}
        $entries += [pscustomobject]@{
            file = $f.Name
            path = $f.FullName
            body = $text
        }
    }
    return $entries
}

function Load-WeeklySchedule {
    param($Paths)
    $default = @{
        last_updated = (Get-Date).ToString('o')
        days = @{
            monday    = @()
            tuesday   = @()
            wednesday = @()
            thursday  = @()
            friday    = @()
            saturday  = @()
            sunday    = @()
        }
    }
    $sched = Read-JsonFile $Paths.Schedule
    if ($sched) { return $sched }
    return $default
}

function List-StandPoses {
    param($Paths)
    $poses = @()
    if (-not (Test-Path -LiteralPath $Paths.Stand)) { return $poses }
    $outfits = Get-ChildItem -LiteralPath $Paths.Stand -Directory -ErrorAction SilentlyContinue
    foreach ($o in $outfits) {
        $files = Get-ChildItem -LiteralPath $o.FullName -Filter '*.png' -File -ErrorAction SilentlyContinue
        foreach ($p in $files) {
            $poses += [pscustomobject]@{
                outfit = $o.Name
                pose   = $p.BaseName
                path   = $p.FullName
                rel    = (Join-Path $o.Name $p.Name)
            }
        }
    }
    return $poses
}

function Load-RecentThoughts {
    param($Paths, [int]$Count = 5)
    $thoughts = @()
    if (Test-Path -LiteralPath $Paths.Thoughts) {
        $lines = Get-Content -LiteralPath $Paths.Thoughts -Encoding UTF8 | Select-Object -Last $Count
        foreach ($ln in $lines) {
            try {
                $obj = $ln | ConvertFrom-Json
                if ($obj.thoughts) { $thoughts += $obj.thoughts }
            } catch {}
        }
    }
    if ($thoughts.Count -lt $Count -and (Test-Path -LiteralPath $Paths.ContextHistory)) {
        $fallback = Get-Content -LiteralPath $Paths.ContextHistory -Encoding UTF8 | Select-Object -Last 30
        foreach ($ln in $fallback) {
            try {
                $obj = $ln | ConvertFrom-Json
                if ($obj.thoughts -and "$($obj.thoughts)".Length -gt 0) { $thoughts += $obj.thoughts }
                if ($thoughts.Count -ge $Count) { break }
            } catch {}
        }
    }
    return @($thoughts | Select-Object -First $Count)
}

function Load-ContextSnapshot {
    param($Paths, [int]$History = 12)
    $ctx = Read-JsonFile $Paths.Context
    $summary = ''
    if ($ctx -and $ctx.summary) { $summary = $ctx.summary }
    $convo = @()
    if (Test-Path -LiteralPath $Paths.ConversationHistory) {
        $lines = Get-Content -LiteralPath $Paths.ConversationHistory -Encoding UTF8 | Select-Object -Last $History
        foreach ($ln in $lines) {
            try {
                $o = $ln | ConvertFrom-Json
                if ($o.role -and $o.content) {
                    $convo += ("{0}: {1}" -f $o.role, $o.content)
                }
            } catch {}
        }
    }
    $emo = Read-JsonFile $Paths.Emotion
    $recentThoughts = Load-RecentThoughts -Paths $Paths
    # Load latest screen caption
    $screenCaption = $null
    if ($Paths.ScreenCaptionHistory -and (Test-Path -LiteralPath $Paths.ScreenCaptionHistory)) {
        try {
            $captionArray = Read-JsonFile $Paths.ScreenCaptionHistory
            if ($captionArray -and $captionArray.Count -gt 0) {
                $screenCaption = $captionArray[-1]  # Get last entry
            }
        } catch {}
    }
    # Load recent wakeup pings and affect reasons to avoid repetition
    $recentPings = @()
    $recentReasons = @()
    if ($Paths.WakePings -and (Test-Path -LiteralPath $Paths.WakePings)) {
        try {
            $pingLines = Get-Content -LiteralPath $Paths.WakePings -Encoding UTF8 | Select-Object -Last 10
            foreach ($ln in $pingLines) {
                try {
                    $p = $ln | ConvertFrom-Json
                    if ($p.content) { $recentPings += $p.content }
                    if ($p.reason) { $recentReasons += $p.reason }
                } catch {}
            }
        } catch {}
    }
    return [pscustomobject]@{
        summary = $summary
        conversation = $convo
        mood = if ($emo) { $emo } else { $null }
        recent_thoughts = $recentThoughts
        screen_caption = $screenCaption
        recent_wakeup_pings = $recentPings
        recent_affect_reasons = $recentReasons
    }
}

function Invoke-LlamaChat {
    param(
        [string]$Server,
        [string]$Model,
        [string]$System,
        [string]$User,
        [object[]]$Messages,
        [int]$MaxTokens = 512,
        [double]$Temperature = 0.7,
        [double]$TopP = 0.9,
        [int]$TimeoutSec = 240,
        [switch]$JsonMode,
        [string]$Label = ''
    )
    $failureLog = $null
    if ($env:ECHO_HOME) {
        $candidate = Join-Path $env:ECHO_HOME 'logs\llama.fail.jsonl'
        $failureLog = $candidate
    }
    function Write-LlamaFailureLog {
        param($Note, $RequestJson, $ResponseRaw)
        if (-not $failureLog) { return }
        try {
            $entry = @{
                ts      = (Get-Date).ToString('o')
                label   = $Label
                server  = $Server
                model   = $Model
                note    = $Note
                request = $RequestJson
                response= $ResponseRaw
            }
            $entry | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $failureLog -Encoding UTF8
        } catch {
            # best-effort logging only
        }
    }
    if (-not $Server) { $Server = 'http://127.0.0.1:8080' }
    $uri = ($Server.TrimEnd('/')) + '/v1/chat/completions'
    $msgs = @()
    if ($System) { $msgs += @{ role = 'system'; content = $System } }
    if ($Messages -and $Messages.Count -gt 0) {
        $msgs += $Messages
    } elseif ($User) {
        $msgs += @{ role = 'user'; content = $User }
    }
    elseif ($User -eq $null) { }
    else { $msgs += @{ role = 'user'; content = '' } }

    $body = @{
        messages     = $msgs
        temperature  = $Temperature
        top_p        = $TopP
        max_tokens   = $MaxTokens
        stream       = $false
    }

    # Only include model if provided and non-empty
    if ($Model -and $Model.Trim()) {
        $body.model = $Model
    }

    if ($JsonMode) {
        $body.response_format = @{ type = 'json_object' }
    }

    $json = $body | ConvertTo-Json -Depth 10 -Compress
    $jsonBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    Write-Verbose "LlamaChat Request: $json"
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -Body $jsonBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec
        if ($resp -and $resp.choices -and $resp.choices.Count -gt 0) {
            $msg = $resp.choices[0].message
            if ($msg -and $msg.content) { return $msg.content }
            # Fallback: surface tool_calls or whole message JSON to avoid swallowing valid outputs
            if ($msg -and $msg.tool_calls) { return ($msg.tool_calls | ConvertTo-Json -Depth 10 -Compress) }
            return ($msg | ConvertTo-Json -Depth 10 -Compress)
        }
        # Response was successful but had no choices; surface the raw payload to the caller
        $raw = ''
        try { $raw = $resp | ConvertTo-Json -Depth 10 -Compress } catch { $raw = [string]$resp }
        $msg = if ($raw) { "LlamaChat: Response received but no choices returned. Raw: $raw" } else { "LlamaChat: Response received but no choices returned." }
        Write-LlamaFailureLog -Note 'no_choices' -RequestJson $json -ResponseRaw $raw
        Write-Warning $msg
        throw [InvalidOperationException]::new($msg)
    } catch {
        # Log the actual error before returning null
        Write-LlamaFailureLog -Note ("exception: {0}" -f $_.Exception.Message) -RequestJson $json -ResponseRaw ''
        Write-Warning "LlamaChat failed: $($_.Exception.Message)"
        Write-Warning "URI: $uri"
        throw
    }
    return $null
}

Export-ModuleMember -Function Get-EchoHome,Get-EchoPaths,Ensure-EchoPaths,Read-JsonFile,Write-JsonFile,Append-Jsonl,Write-LogLine,Load-DiaryEntries,Load-WeeklySchedule,List-StandPoses,Load-RecentThoughts,Load-ContextSnapshot,Invoke-LlamaChat
