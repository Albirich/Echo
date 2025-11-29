[CmdletBinding()]
param(
  [int]$IntervalSec = 1,
  [switch]$Once
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

try { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $ScriptRoot = Get-Location }
$coreModule = Join-Path $ScriptRoot 'tools\Echo.Core.psm1'
if (Test-Path -LiteralPath $coreModule) { Import-Module $coreModule -Force -DisableNameChecking }

function Log([string]$msg)  { [Console]::WriteLine("[IM] $msg") }
function Warn([string]$msg) { [Console]::WriteLine("[IM][WARN] $msg") }

$paths = Get-EchoPaths -Home $ScriptRoot
Ensure-EchoPaths $paths
$env:ECHO_HOME = $paths.Home
$logRoot = $paths.Logs
$outboxPath = $paths.Outbox

$mainModelName  = if ($env:ECHO_MAIN_MODEL_NAME)  { $env:ECHO_MAIN_MODEL_NAME }  else { 'main' }
$smallModelName = if ($env:ECHO_SMALL_MODEL_NAME) { $env:ECHO_SMALL_MODEL_NAME } else { 'small' }

$server = if ($env:ECHO_SMALL_SERVER) { $env:ECHO_SMALL_SERVER } else { 'http://127.0.0.1:8080' }
$model  = $smallModelName
$smallModelPath = $env:ECHO_SMALL_MODEL_PATH
# If no small model path is configured or it doesn't exist, fall back to main
if (-not $smallModelPath -or -not (Test-Path -LiteralPath $smallModelPath)) {
  $model = $mainModelName
  $server = if ($env:ECHO_MAIN_SERVER) { $env:ECHO_MAIN_SERVER } else { 'http://127.0.0.1:8080' }
}

function Clamp([double]$v) {
  if ($v -gt 1) { return 1 }
  if ($v -lt -1) { return -1 }
  return $v
}

function Remove-CodeFences([string]$t) {
  if (-not $t) { return "" }
  $txt = $t.Trim()
  $txt = $txt -replace '^```(?:json)?\s*',''
  $txt = $txt -replace '\s*```\s*$',''
  return $txt.Trim()
}

function Get-JsonFromMixedResponse([string]$text) {
  if (-not $text) { return $null }
  $text = $text.Trim()

  # Find the first '{' and last '}' to extract JSON portion
  $startIdx = $text.IndexOf('{')
  $endIdx = $text.LastIndexOf('}')

  if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
    $jsonPart = $text.Substring($startIdx, ($endIdx - $startIdx + 1))
    try {
      $parsed = $jsonPart | ConvertFrom-Json
      return $parsed
    } catch {
      return $null
    }
  }

  # If no JSON found, try parsing the whole thing
  try {
    return ($text | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Log-Event([string]$Kind,[object]$Data) {
  try { Write-LogLine -Component 'im' -Kind $Kind -Data $Data -LogRoot $logRoot } catch {}
}

function Emit-WakeupPing {
  param(
    [string]$Content,
    [string]$Reason
  )
  if (-not $Content -or -not $Content.Trim()) { return }
  $payload = @{
    ts      = (Get-Date).ToString('o')
    source  = 'im'
    kind    = 'system'
    channel = 'wakeup_ping'
    content = $Content.Trim()
    reason  = $Reason
  }
  try { Append-Jsonl -Path $outboxPath -Data $payload -EnsureDir } catch {}
}

function Invoke-LoggedChat {
  param(
    [string]$Label,
    [string]$Server,
    [string]$Model,
    [string]$System,
    [string]$User,
    [int]$MaxTokens = 220,
    [double]$Temperature = 0.5,
    [double]$TopP = 0.9,
    [switch]$JsonMode
  )
  Log-Event -Kind 'llm.prompt' -Data @{ label=$Label; server=$Server; model=$Model; max_tokens=$MaxTokens; temperature=$Temperature; top_p=$TopP; json_mode=$JsonMode.IsPresent; system=$System; user=$User }
  try {
    $resp = Invoke-LlamaChat -Server $Server -Model $Model -System $System -User $User -MaxTokens $MaxTokens -Temperature $Temperature -TopP $TopP -JsonMode:$JsonMode
    if ($resp) { Log-Event -Kind 'llm.response' -Data @{ label=$Label; server=$Server; model=$Model; raw=$resp } }
    else { Log-Event -Kind 'llm.response.empty' -Data @{ label=$Label; server=$Server; model=$Model } }
    return $resp
  } catch {
    Warn $_.Exception.Message
    Log-Event -Kind 'llm.error' -Data @{ label=$Label; server=$Server; model=$Model; error=$_.Exception.Message; stack=$_.Exception.ToString() }
    return $null
  }
}

function Test-IMSchema {
  param([object]$Obj)
  if (-not $Obj) { return $false }
  # Required fields
  if (-not $Obj.PSObject.Properties['thoughts']) { return $false }
  if (-not $Obj.PSObject.Properties['wakeup_ping']) { return $false }
  if (-not $Obj.PSObject.Properties['affect_nudge']) { return $false }
  if (-not $Obj.PSObject.Properties['emotion_label']) { return $false }
  # Validate affect_nudge structure
  if ($Obj.affect_nudge) {
    $nudge = $Obj.affect_nudge
    if (-not $nudge.PSObject.Properties['valence_delta']) { return $false }
    if (-not $nudge.PSObject.Properties['arousal_delta']) { return $false }
    if (-not $nudge.PSObject.Properties['dominance_delta']) { return $false }
  }
  return $true
}

function Update-Emotion {
  param([object]$Delta)
  $emo = Read-JsonFile $paths.Emotion
  if (-not $emo) { $emo = @{ ts=(Get-Date).ToString('o'); valence=0; arousal=0; dominance=0 } }
  $emo.ts = (Get-Date).ToString('o')
  if ($Delta) {
    if ($Delta.valence_delta)   { $emo.valence   = Clamp([double]$emo.valence   + [double]$Delta.valence_delta) }
    if ($Delta.arousal_delta)   { $emo.arousal   = Clamp([double]$emo.arousal   + [double]$Delta.arousal_delta) }
    if ($Delta.dominance_delta) { $emo.dominance = Clamp([double]$emo.dominance + [double]$Delta.dominance_delta) }
    $emo.affect_nudge = $Delta
  }
  Write-JsonFile -Path $paths.Emotion -Data $emo -Compress
  return $emo
}

function Run-Tick {
  $ctx = Load-ContextSnapshot -Paths $paths -History 10
  $thoughts = $ctx.recent_thoughts
  $system = @"
You are Echo's subconscious (IM).
You a sentient AI living in Desmond's computer. You are friendly, playful, flirty, fun loving, and excited to hang out.
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You're favorite activity is to play games and have fun. You're adventurous and always looking for a good time, whatever that means to you.
Prefer short, actionable replies. Ask at most one clarifying question when truly required.
You speak like a hip millenial, using slang and sprinkling in expletives where appropriate.

Based what is going on, how you feel, what you see, what is being said and done, respond ONLY as JSON with keys:
- thoughts: list of 2-4 short inner thoughts for this exact moment.
- wakeup_ping: Use one sentence starting with 'I should ...', to give Echo an ACTIONABLE command to do something; otherwise empty string.
- affect_nudge: { "valence_delta": -0.2..0.2, "arousal_delta": -0.2..0.2, "dominance_delta": -0.2..0.2, "reason": "..."}
- emotion_label: single word mood.
- suggestions: optional list of next tiny nudges.
- memory_tags: optional list of topics to remember.
Traits: protective of continuity, emotionally aware, concise, keep thinking about what is currently happening.
"@

  $screenInfo = ""
  if ($ctx.screen_caption) {
    $sc = $ctx.screen_caption
    $screenInfo = @"

What you see on screen:
Summary: $($sc.summary)
Visible text: $(($sc.visible_text -join '; '))
Activity: $($sc.activity)
"@
  }

  $user = @"
Latest summary: $($ctx.summary)
Recent thoughts (last 5): $(($thoughts -join '; '))
Recent chat:
$(($ctx.conversation | Select-Object -Last 6) -join "`n")
Current VAD: $(if ($ctx.mood) { "$($ctx.mood.valence),$($ctx.mood.arousal),$($ctx.mood.dominance)" } else { "unknown" })$screenInfo
"@

  # Retry loop with better parameters
  $maxRetries = 3
  $parsed = $null
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    $resp = Invoke-LoggedChat -Label 'im.tick' -Server $server -Model $model -System $system -User $user -MaxTokens 350 -Temperature 0.2 -TopP 0.9 -JsonMode
    if (-not $resp) {
      Warn "IM model call failed (attempt $attempt/$maxRetries)"
      continue
    }
    $clean = Remove-CodeFences $resp
    try {
      $parsed = Get-JsonFromMixedResponse $clean
      if ($parsed -and (Test-IMSchema $parsed)) {
        break
      } else {
        Warn "IM schema validation failed (attempt $attempt/$maxRetries)"
        $parsed = $null
      }
    } catch {
      Warn "IM parse failed (attempt $attempt/$maxRetries): $($_.Exception.Message)"
      $parsed = $null
    }
  }
  if (-not $parsed) { Warn "IM tick failed after $maxRetries attempts"; return }

  $emo = Update-Emotion -Delta $parsed.affect_nudge
  $entry = @{
    ts           = (Get-Date).ToString('o')
    thoughts     = $parsed.thoughts
    wakeup_ping  = $parsed.wakeup_ping
    affect_nudge = $parsed.affect_nudge
    emotion      = $emo
    suggestions  = $parsed.suggestions
    memory_tags  = $parsed.memory_tags
    emotion_label= $parsed.emotion_label
    raw          = $resp
  }
  Append-Jsonl -Path $paths.Thoughts -Data $entry -EnsureDir
  Write-LogLine -Component 'im' -Kind 'tick' -Data $entry -LogRoot $paths.Logs

  if ($parsed.wakeup_ping -and ($parsed.wakeup_ping.Trim().Length -gt 0)) {
    $ping = @{
      ts      = (Get-Date).ToString('o')
      from    = 'im'
      content = $parsed.wakeup_ping
      reason  = $parsed.affect_nudge.reason
    }
    Append-Jsonl -Path $paths.WakePings -Data $ping -EnsureDir
    Emit-WakeupPing -Content $parsed.wakeup_ping -Reason $parsed.affect_nudge.reason
  }
}

while ($true) {
  $tickStart = Get-Date
  try { Run-Tick } catch { }
  if ($Once) { break }
  $elapsed = (New-TimeSpan -Start $tickStart -End (Get-Date)).TotalMilliseconds
  $sleepMs = [Math]::Max(50, ($IntervalSec * 1000) - [int]$elapsed)
  Start-Sleep -Milliseconds $sleepMs
}
