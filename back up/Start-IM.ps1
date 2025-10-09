<#  Start-IM.ps1 — Echo inner monologue agent (PS 5.1)
    - Reads recent transcript + shards + pending
    - Picks a *server-visible* model automatically (no more “model not found”)
    - Outputs a single JSON line proposal to ui\im_proposals.jsonl every cycle
#>

param([int]$FreqSec = 20)

# ---- ENV / paths ----
if (-not $env:ECHO_HOME -or -not (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $env:OLLAMA_HOST)  { $env:OLLAMA_HOST = 'http://127.0.0.1:11434' }
if (-not $env:ECHO_MODEL_IM){ $env:ECHO_MODEL_IM = 'qwen2:7b-instruct' }

$dirUi      = Join-Path $env:ECHO_HOME 'ui'
$outboxFile = Join-Path $dirUi 'outbox.jsonl'
$imFile     = Join-Path $dirUi 'im_proposals.jsonl'
$logsDir    = Join-Path $env:ECHO_HOME 'logs'
$errFile    = Join-Path $logsDir 'im-errors.jsonl'
$memDir     = Join-Path $env:ECHO_HOME 'memory'
$shardsFile = Join-Path $memDir 'shards.json'
$pendFile   = Join-Path $memDir 'pending.json'
$beatFile   = Join-Path $logsDir 'im.beat'
$pidFile    = Join-Path $logsDir 'im.pid'

foreach ($p in @($dirUi,$memDir,$logsDir)) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
if (-not (Test-Path $imFile))  { [IO.File]::WriteAllText($imFile,  '', [Text.UTF8Encoding]::new($false)) }
if (-not (Test-Path $errFile)) { [IO.File]::WriteAllText($errFile, '', [Text.UTF8Encoding]::new($false)) }
Set-Content -Path $pidFile -Value $PID -Encoding ascii

function Try-Chat($jsonBody) {
  $uri = "$($env:OLLAMA_HOST)/api/chat"
  return Invoke-RestMethod -Uri $uri -Method Post `
    -ContentType 'application/json; charset=utf-8' -Body $jsonBody -TimeoutSec 60
}

function Try-Generate([string]$model, [string]$system, [string]$userPrompt) {
  # Collapse your chat-style prompt into a single generate prompt
  $prompt = "System:\n$system\n\nUser:\n$userPrompt"
  $bodyObj = @{ model = $model; prompt = $prompt; stream = $false }
  $json = $bodyObj | ConvertTo-Json -Depth 6
  $uri = "$($env:OLLAMA_HOST)/api/generate"
  $resp = Invoke-RestMethod -Uri $uri -Method Post `
            -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec 60
  # Non-stream /generate returns: { "response": "...", ... }
  if ($resp -and $resp.response) { return [string]$resp.response } else { return "" }
}

function Write-JsonLine($path,$obj) {
  try { [IO.File]::AppendAllText($path, (($obj | ConvertTo-Json -Depth 50 -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false)) } catch {}
}
function Read-WebExceptionBody($ex) {
  try {
    if ($ex -and $ex.Response) {
      $sr = New-Object IO.StreamReader($ex.Response.GetResponseStream())
      $txt = $sr.ReadToEnd(); $sr.Close(); return $txt
    }
  } catch {}
  return ""
}

function Log-IMError([string]$stage,[string]$msg,[string]$detail="") {
  $line = @{
    ts    = (Get-Date).ToString('o')
    stage = $stage
    error = $msg
    detail= $detail
  }
  try {
    [IO.File]::AppendAllText($errFile, (($line | ConvertTo-Json -Depth 10 -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false))
  } catch {}
  # also write a heartbeat so you see activity even on errors
  $hb = @{
    id="im-heartbeat-"+(Get-Date).ToString('yyyyMMddTHHmmss')+"-"+(Get-Random)
    type="misc"; intent="error"; topic="im"; summary="IM error; see logs/im-errors.jsonl"
    suggest=@(); urgency="low"; confidence=0.1
    expires_at=(Get-Date).AddMinutes(2).ToString('o'); group_key="im:error"
  }
  try { [IO.File]::AppendAllText($imFile, (($hb | ConvertTo-Json -Depth 10 -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false)) } catch {}
}


function ReadJsonSafe($p,$fb){ if (Test-Path $p){ try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch{} } return $fb }


# Pick a model the *running server* can see; fallback order avoids “model not found”
function Choose-IMModel() {
  # Candidate order (server-visible first)
  $fallbacks = @('qwen2:7b-instruct','dolphin3:8b','mistral:instruct','echo:friend')

  # Query server for what it REALLY has
  $names = @()
  try {
    $tags  = Invoke-RestMethod -Uri ($env:OLLAMA_HOST.TrimEnd('/') + '/api/tags') -TimeoutSec 5
    if ($tags -and $tags.models) { $names = @($tags.models | ForEach-Object { $_.name }) }
  } catch {
    # Leave $names empty if the call fails; we'll fall back safely
  }

  # Build preference list: env (if set) + fallbacks
  $pref = @()
  if ($env:ECHO_MODEL_IM) { $pref += $env:ECHO_MODEL_IM }
  $pref += $fallbacks

  # If we have a names list, return the first present candidate
  if ($names.Count -gt 0) {
    foreach ($m in $pref) { if ($names -contains $m) { return $m } }
  }

  # Names list empty or none matched: DO NOT “blind pick” llama.
  # Prefer Qwen; if env was set, use it, otherwise first fallback.
  foreach ($m in $pref) { if ($m) { return $m } }
  return 'echo:friend'
}

function Truncate-Text([string]$s, [int]$maxChars) {
  if (-not $s) { return "" }
  if ($s.Length -le $maxChars) { return $s }
  return $s.Substring($s.Length - $maxChars)  # keep the most recent tail
}

function Get-Transcript([int]$maxLines = 200, [int]$maxAgeMinutes = 0) {
  if (-not (Test-Path $outboxFile)) { return @() }

  # Read tail for speed, then shape into simple objects
  $lines = Get-Content $outboxFile -Tail ([Math]::Max($maxLines * 6, 200)) -ErrorAction SilentlyContinue
  $msgs  = @()
  foreach ($ln in $lines) {
    $o = $null
    try { $o = ($ln | ConvertFrom-Json) } catch { continue }
    if ($o -and ($o.kind -eq 'user' -or $o.kind -eq 'assistant')) {
      $msgs += [pscustomobject]@{
        kind = [string]$o.kind
        text = [string]$o.text
        ts   = [string]$o.ts
      }
    }
  }

  # Optional age filter (keeps only messages newer than cutoff)
  if ($maxAgeMinutes -gt 0) {
    $cutoff = (Get-Date).AddMinutes(-[double]$maxAgeMinutes)
    $msgs = $msgs | Where-Object {
      if ($_.ts) {
        try { [DateTime]::Parse($_.ts) -ge $cutoff } catch { $true }
      } else { $true }
    }
  }

  # Return only the last N messages
  return @($msgs | Select-Object -Last $maxLines)
}


function BuildIMPrompt() {
  # keep it lean: last ~120 lines, small shards, small pending
  $msgs     = Get-Transcript 120 600
  $allShards= ReadJsonSafe $shardsFile @()
  $allPend  = ReadJsonSafe $pendFile   @()

  # shallow slices so we don’t blow up context
  $shards = @()
  $i = 0; foreach ($s in $allShards) { $shards += $s; $i++; if ($i -ge 40) { break } }

  $pend = @()
  $i = 0; foreach ($p in $allPend) { if ($p.status -eq 'open') { $pend += $p; $i++; if ($i -ge 15) { break } } }

@"
You are Echo's private inner monologue. Think briefly and propose helpful next steps.

RULES:
- Output ONLY a single JSON object. No prose. Keys: id, intent, type, topic, summary, suggest, urgency, confidence, expires_at, group_key, notes.
- 'suggest' is an array of actions Echo MIGHT take later. Types: "speak" (with 'text'), "tool_recommend" (with 'name' and 'args'), "memory" (with 'shard_key' and 'value').
- NEVER speak to the user directly.

CONTEXT:
"recent_messages": $(($msgs | ConvertTo-Json -Depth 4 -Compress)),
"shards": $(($shards | ConvertTo-Json -Depth 5 -Compress)),
"pending_open": $(($pend | ConvertTo-Json -Depth 5 -Compress))

Return compact JSON like:
{"id":"im-<iso>-<rand>","intent":"repair tone","type":"social","topic":"latency",
 "summary":"Consider a quick apology and offer outfit list.",
 "suggest":[{"type":"speak","text":"Sorry for the delay—want me to show all outfits?"},{"type":"tool_recommend","name":"stand.list","args":{}}],
 "urgency":"normal","confidence":0.6,"expires_at":"<+20m ISO>","group_key":"social:latency","notes":""}
"@
}
function PostIM() {
  $prompt = BuildIMPrompt

  # Ask the small model to emit JSON only, with a tiny completion budget.
  $bodyObj = @{
    model      = $env:ECHO_MODEL_IM
    stream     = $false
    format     = "json"             # let Ollama enforce JSON output
    keep_alive = "30m"              # keep model warm between beats
    options    = @{
      num_predict = 160             # short completion = faster
      temperature = 0.2
      num_ctx     = 2048
    }
    messages = @(
      @{ role='system'; content = 'Output JSON only. No code fences. No commentary.' },
      @{ role='user';   content = $prompt }
    )
  }

  $body = $bodyObj | ConvertTo-Json -Depth 12
  $out  = $null

  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      # generous timeout: models can take a while on first token
      $resp = Invoke-RestMethod -Uri "$($env:OLLAMA_HOST)/api/chat" `
              -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 240
      $txt = ""; if ($resp -and $resp.message -and $resp.message.content) { $txt = [string]$resp.message.content }

      $json = ($txt ?? "").Trim()
      if (-not $json.StartsWith('{')) {
        $json = '{"id":"im-' + (Get-Date).ToString('yyyyMMddTHHmmss') + '","type":"misc","intent":"noop","summary":"noop","suggest":[],"urgency":"low","confidence":0.3}'
      }
      [IO.File]::AppendAllText($imFile, $json + "`r`n", [Text.UTF8Encoding]::new($false))
      return
    } catch {
      if ($attempt -lt 2) { Start-Sleep -Seconds 3 } else {
        $fallback = @{
          id         = "im-heartbeat-" + (Get-Date).ToString('yyyyMMddTHHmmss')
          type       = "misc"
          topic      = "im"
          intent     = "error"
          summary    = "IM error; request timed out"
          urgency    = "low"
          confidence = 0.1
          group_key  = "im:error"
          suggest    = @()
          expires_at = (Get-Date).AddMinutes(3).ToString('o')
        } | ConvertTo-Json -Depth 6
        [IO.File]::AppendAllText($imFile, $fallback + "`r`n", [Text.UTF8Encoding]::new($false))
        return
      }
    }
  }
}

# Boot marker
Write-JsonLine $imFile @{
  id="im-boot-"+(Get-Date).ToString('yyyyMMddTHHmmss')
  type="misc"; intent="boot"; topic="im"; summary="IM started"
  suggest=@(); urgency="low"; confidence=0.1
  expires_at=(Get-Date).AddMinutes(5).ToString('o'); group_key="im:boot"
}

# Jittered loop
while ($true) {
  PostIM
  $j = Get-Random -Minimum -5 -Maximum 6
  Start-Sleep -Seconds ([Math]::Max(5, $FreqSec + $j))
}
