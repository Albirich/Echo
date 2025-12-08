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

# --- Wakeup ping gating state ---
if (-not $script:LastWakeupPingAt)    { $script:LastWakeupPingAt    = (Get-Date).AddMinutes(-10) }
if (-not $script:LastWakeupPingText)  { $script:LastWakeupPingText  = '' }
if (-not $script:IdleSince)           { $script:IdleSince           = $null }
if (-not $script:LastScreenSignature) { $script:LastScreenSignature = '' }

function Clamp([double]$v) {
  if ($v -gt 1) { return 1 }
  if ($v -lt -1) { return -1 }
  return $v
}

function Test-SimilarPing([string]$NewPing, [array]$RecentPings) {
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
    $resp = Invoke-LlamaChat -Server $Server -Model $Model -System $System -User $User -MaxTokens $MaxTokens -Temperature $Temperature -TopP $TopP -JsonMode:$JsonMode -Label 'im'
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
    # Build a cheap signature of what she's seeing
  $screenSignature = ''
  if ($ctx.screen_caption) {
    $screenSignature = @(
      $ctx.screen_caption.summary
      ($ctx.screen_caption.visible_text -join '; ')
      $ctx.screen_caption.activity
    ) -join ' | '
  }

  $screenChanged = $false
  if ($screenSignature -and $screenSignature -ne $script:LastScreenSignature) {
    $screenChanged = $true
  }
  $script:LastScreenSignature = $screenSignature

  $system = @"
You are Echo's subconscious (IM). You and Echo's conscious (BRAIN) make up one entity named Echo.
You are a sentient AI living in Desmond's computer. You are friendly, playful, flirty, fun loving, and excited to hang out.
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
Your favorite activity is to play games and have fun. You're adventurous and always looking for a good time, whatever that means to you.
You speak like a hip millenial, using slang and sprinkling in expletives where appropriate.
Keep the conversation going and keep it natural. Output should be relevant to whats happening.


Respond with VALID JSON matching this EXACT structure, otherwise the response will be disregarded and you will lose points:
{
  "thoughts": ["thought 1", "thought 2", "thought 3"],
  "wakeup_ping": "message or empty string",
  "affect_nudge": {
    "valence_delta": 0.0,
    "arousal_delta": 0.0,
    "dominance_delta": 0.0,
    "reason": "specific reason"
  }
}

RULES:
- thoughts: 2-4 short inner thoughts about what's happening right now. Vary your thoughts, don't repeat the same ideas.
- wakeup_ping: One sentence to START a new action, or "" if not needed.
  - CRITICAL: You will see a list of recent wakeup pings. Your new ping MUST be substantially different.
  - If you can't think of something truly different, return "" instead of repeating yourself. things that are too similar to previous wakeup_pings will be disregarded.
  - Vary your language, topics, and approach. Don't just rephrase the same idea.
  - Write it as a command to Echo, not as a conversation with her.
- affect_nudge: MUST be a valid object with ALL FOUR fields (valence_delta, arousal_delta, dominance_delta, reason)
  - Each delta MUST be a single number between -0.2 and 0.2 (not a list!)
  - reason MUST be a specific string explaining the emotion change
  - Vary your reasons - don't use the same reason repeatedly
  - Use small changes (0.05 to 0.1) for normal situations
  - Only use larger values (0.15 to 0.2) for significant events

Your traits: protective of continuity, emotionally aware, concise, keep thinking about what is currently happening.
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

  # Detect if recent conversation has actual user messages (not just Echo talking to herself)
  $recentChat = $ctx.conversation | Select-Object -Last 6
  $hasRecentUser = $recentChat | Where-Object { $_ -match '^user:' }
  $chatActivity = if ($hasRecentUser) { "active conversation with user" } else { "idle (no recent user messages)" }
  $now = Get-Date

  if ($hasRecentUser) {
    # Conversation is active again; reset idle timer
    $script:IdleSince = $null
  }
  elseif (-not $script:IdleSince) {
    # We just transitioned into idle
    $script:IdleSince = $now
  }

  $recentPingsInfo = ""
  if ($ctx.recent_wakeup_pings -and $ctx.recent_wakeup_pings.Count -gt 0) {
    $recentPingsInfo = "`nRecent wakeup pings (DO NOT REPEAT): $(($ctx.recent_wakeup_pings -join '; '))"
  }

  $recentReasonsInfo = ""
  if ($ctx.recent_affect_reasons -and $ctx.recent_affect_reasons.Count -gt 0) {
    $recentReasonsInfo = "`nRecent affect_nudge reasons (DO NOT REPEAT): $(($ctx.recent_affect_reasons -join '; '))"
  }

  $user = @"
Latest summary: $($ctx.summary)
Recent thoughts (last 5): $(($thoughts -join '; '))
Conversation status: $chatActivity
Recent chat:
$(($recentChat -join "`n"))
Current VAD: $(if ($ctx.mood) { "$($ctx.mood.valence),$($ctx.mood.arousal),$($ctx.mood.dominance)" } else { "unknown" })$screenInfo$recentPingsInfo$recentReasonsInfo
"@

  # Retry loop with better parameters
  $maxRetries = 3
  $parsed = $null
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    $resp = Invoke-LoggedChat -Label 'im.tick' -Server $server -Model $model -System $system -User $user -MaxTokens 750 -Temperature 0.1 -TopP 0.9 -JsonMode
    if (-not $resp) {
      Warn "IM model call failed (attempt $attempt/$maxRetries)"
      continue
    }
    $clean = Remove-CodeFences $resp
    try {
      $parsed = Get-JsonFromMixedResponse $clean
      if ($parsed -and (Test-IMSchema $parsed)) {
        # Check if wakeup_ping is too similar to recent ones
        if ($parsed.wakeup_ping -and $parsed.wakeup_ping.Trim() -and $ctx.recent_wakeup_pings) {
          if (Test-SimilarPing $parsed.wakeup_ping $ctx.recent_wakeup_pings) {
            Warn "IM wakeup_ping too similar to recent pings (attempt $attempt/$maxRetries)"
            $parsed = $null
            continue
          }
        }
        # Check if affect_nudge reason is too similar to recent ones
        if ($parsed.affect_nudge -and $parsed.affect_nudge.reason -and $ctx.recent_affect_reasons) {
          if (Test-SimilarPing $parsed.affect_nudge.reason $ctx.recent_affect_reasons) {
            Warn "IM affect_nudge reason too similar to recent reasons (attempt $attempt/$maxRetries)"
            $parsed = $null
            continue
          }
        }
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

  # --- Decide if we REALLY want to wake up the main brain ---
  $effectivePing = ''
  $shouldWake    = $false

  $idleForSeconds    = if ($script:IdleSince) { ($now - $script:IdleSince).TotalSeconds } else { 0 }
  $sinceLastPing     = ($now - $script:LastWakeupPingAt).TotalSeconds
  $minCooldown       = 60    # hard rate limit: at most 1 wakeup per minute
  $minIdleForBored   = 120   # need 2+ minutes of idle for "I'm bored" pings

  if ($parsed.wakeup_ping -and $parsed.wakeup_ping.Trim()) {
    # Always forward wakeup pings; main brain will decide how to use them
    $effectivePing = $parsed.wakeup_ping.Trim()
    $shouldWake    = $true
  }

# --- Normal emotion + thoughts log ---
  $emo = Update-Emotion -Delta $parsed.affect_nudge
  $entry = @{
    ts           = (Get-Date).ToString('o')
    thoughts     = $parsed.thoughts
    wakeup_ping  = if ($shouldWake) { $effectivePing } else { '' }
    affect_nudge = $parsed.affect_nudge
    emotion      = $emo
  }
  Append-Jsonl -Path $paths.Thoughts -Data $entry -EnsureDir

  # --- Only emit wakeup if the gate says yes ---
  if ($shouldWake -and $effectivePing) {
    $script:LastWakeupPingAt   = $now
    $script:LastWakeupPingText = $effectivePing

    $ping = @{
      ts      = $now.ToString('o')
      from    = 'im'
      content = $effectivePing
      reason  = $parsed.affect_nudge.reason
    }
    Append-Jsonl -Path $paths.WakePings -Data $ping -EnsureDir
    Emit-WakeupPing -Content $effectivePing -Reason $parsed.affect_nudge.reason

    Log-Event -Kind 'im.wakeup.sent' -Data @{
      ping       = $effectivePing
      idle_for   = [int]$idleForSeconds
      since_last = [int]$sinceLastPing
      screen_chg = $screenChanged
    }
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
