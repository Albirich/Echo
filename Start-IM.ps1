<# ============================
 Start-IM.ps1  (clean rewrite)
 - Stable ticks + heartbeat log
 - Uses main Ollama instance (11434)
 - Circuit breaker for resilience
 - keep_alive for performance
 - Minimal, robust IM prompt
 - VAD + affect_nudge writer
 - No $PID writes, PS 5.1 safe
============================= #>

[CmdletBinding()]
param(
  [int]$IntervalSec = 3,
  [switch]$Once
)

# ---------- Basics & paths ----------
function IsoNow { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
function Ensure-Dir($p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Append-Jsonl { param([string]$Path,[object]$Obj)
  $line = ($Obj | ConvertTo-Json -Compress)
  Add-Content -Path $Path -Value $line
}

function Write-JsonFile { param([string]$Path,[object]$Obj,[switch]$Compress)
  $json = if ($Compress) { ($Obj | ConvertTo-Json -Compress) } else { ($Obj | ConvertTo-Json) }
  Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Read-JsonSafe { param([string]$Path)
  if (Test-Path $Path) {
    try { return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  } else { return $null }
}

# ---------- Home & files ----------
$EchoHome = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { Join-Path $PSScriptRoot '..' | Resolve-Path | % Path }
$StateDir = Join-Path $EchoHome 'state'
$LogsDir  = Join-Path $EchoHome 'logs'
$DataDir  = Join-Path $EchoHome 'data'
Ensure-Dir $StateDir; Ensure-Dir $LogsDir; Ensure-Dir $DataDir

$CtxNowPath   = Join-Path $StateDir 'context.json'
$CtxHistPath  = Join-Path $StateDir 'context_history.jsonl'
$VADPath      = Join-Path $StateDir 'emotion.vad.json'
$PrefsPath    = Join-Path $DataDir  'prefs.json'
$EpisPath     = Join-Path $DataDir  'episodic.jsonl'
$TodayPath    = Join-Path $DataDir  'today.json'
$SuggestionsPath = Join-Path $StateDir 'suggestions.json'

if (-not (Test-Path $StateDir))        { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
if (-not (Test-Path $SuggestionsPath)) { Set-Content -Path $SuggestionsPath -Value '[]' -Encoding UTF8 }

$TickLog      = Join-Path $LogsDir 'im_heartbeat.jsonl'
$IMReqLog     = Join-Path $LogsDir 'im_requests.log'
$IMErrLog     = Join-Path $LogsDir 'im_ollama_errors.log'

# ---------- IM host/model ----------
$IMHost = if ($env:IM_HOST -and $env:IM_HOST.Trim()) { 
    $env:IM_HOST 
} elseif ($env:OLLAMA_HOST -and $env:OLLAMA_HOST.Trim()) { 
    $env:OLLAMA_HOST 
} else { 
    'http://127.0.0.1:11434' 
}

$IMModel = 'qwen2.5:3b'
# Force GPU usage
$env:OLLAMA_NUM_GPU = "999"
Write-Host "[IM] Ollama host: $IMHost"
Write-Host "[IM] Model: $IMModel"

# ---------- Circuit breaker ----------
$script:ErrorCount = 0
$script:LastErrorTime = $null
$script:CircuitOpen = $false
$script:CircuitOpenUntil = $null

function Test-CircuitBreaker {
    if ($script:CircuitOpen) {
        if ((Get-Date) -gt $script:CircuitOpenUntil) {
            Write-Host "[IM] Circuit breaker RESET - attempting calls again"
            $script:CircuitOpen = $false
            $script:ErrorCount = 0
            return $true
        }
        return $false
    }
    return $true
}

function Trip-CircuitBreaker {
    param([string]$Reason)
    $script:CircuitOpen = $true
    $script:CircuitOpenUntil = (Get-Date).AddSeconds(30)
    Write-Host "[IM] ⚠️ CIRCUIT BREAKER TRIPPED: $Reason - cooling down for 30s"
    Log-Text $IMErrLog "CIRCUIT BREAKER: $Reason"
}

# ---------- User32 interop (active window + idle) ----------
$interopSrc = @"
using System;
using System.Runtime.InteropServices;

public static class Win32IM {
  [StructLayout(LayoutKind.Sequential)]
  public struct LASTINPUTINFO {
    public uint cbSize;
    public uint dwTime;
  }

  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
}
"@
try { Add-Type -TypeDefinition $interopSrc -ErrorAction SilentlyContinue } catch { }

function Get-IdleSeconds {
  try {
    $lii = New-Object Win32IM+LASTINPUTINFO
    $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    [void][Win32IM]::GetLastInputInfo([ref]$lii)
    $tickNow = [Environment]::TickCount
    $idleMs = ($tickNow - [int]$lii.dwTime)
    if ($idleMs -lt 0) { $idleMs = 0 }
    return [math]::Round($idleMs/1000,1)
  } catch { return $null }
}

function Get-ActiveWindowInfo {
  $title = ""; $procId = $null; $procName = $null
  try {
    $h = [Win32IM]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero) {
      $len = [Win32IM]::GetWindowTextLength($h)
      $sb = New-Object System.Text.StringBuilder ([Math]::Max($len+1, 1))
      [void][Win32IM]::GetWindowText($h, $sb, $sb.Capacity)
      $title = $sb.ToString()

      [uint32]$pid32 = 0
      [void][Win32IM]::GetWindowThreadProcessId($h, [ref]$pid32)
      $procId = [int]$pid32
      try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $procName = $null }
    }
  } catch { }
  return [ordered]@{
    title       = $title
    process_id  = $procId
    process     = $procName
  }
}

# ---------- Telemetry snapshot ----------
function Collect-Telemetry {
  $active = Get-ActiveWindowInfo
  $idle = Get-IdleSeconds
  $now = Get-Date
  return [ordered]@{
    ts               = IsoNow
    local_time       = $now.ToString("yyyy-MM-dd HH:mm:ss")
    idle_sec         = $idle
    active_window    = $active
    input            = @{ typing = $false; mouse_moved = $false } # placeholders; wire later if desired
  }
}

# ---------- VAD + mood ----------
function Compute-VAD {
  param([hashtable]$Tele, [pscustomobject]$Prev)
  
  $hour = (Get-Date).Hour
  $idle = if ($Tele.idle_sec -ne $null) { [double]$Tele.idle_sec } else { 0.0 }
  
  # Start from previous state or baseline
  if ($Prev) {
    $val = [double]$Prev.valence
    $aro = [double]$Prev.arousal  
    $dom = [double]$Prev.dominance
  } else {
    # Initial baseline only
    $val = 0.6
    $aro = 0.45
    $dom = 0.55
  }
  
  # Small nudges based on context
  if ($hour -ge 22 -or $hour -le 6) { 
    $aro -= 0.02  # Slight fatigue at night
    $val -= 0.01
  }
  
  if ($idle -gt 120) { 
    $aro -= 0.03  # Getting drowsy
  } elseif ($idle -lt 10) { 
    $aro += 0.02  # Active = slight arousal increase
    $dom += 0.01
  }
  
  # Boredom drift - valence slowly decreases when idle
  if ($idle -gt 30) {
    $val -= 0.005 * ($idle / 30)  # Gradual boredom
    $aro += 0.003 * ($idle / 30)  # Restlessness builds
  }
  
  # Clamp to valid range
  $clamp = { param($x) [math]::Max(0.0, [math]::Min(1.0, [double]$x)) }
  $val = & $clamp $val
  $aro = & $clamp $aro
  $dom = & $clamp $dom
  
  # Affect nudge suggestions for homeostasis
  $nud = @{
    valence_delta   = if ($val -lt 0.35) { +0.08 } elseif ($val -gt 0.8) { -0.04 } else { 0.0 }
    arousal_delta   = if ($aro -gt 0.75) { -0.1 } elseif ($aro -lt 0.25) { +0.08 } else { 0.0 }
    dominance_delta = if ($dom -lt 0.35) { +0.06 } elseif ($dom -gt 0.85) { -0.04 } else { 0.0 }
    reason          = "homeostasis nudge: idle=$idle, hour=$hour"
  }
  
  return [pscustomobject]@{
    ts           = IsoNow
    valence      = [math]::Round($val, 3)
    arousal      = [math]::Round($aro, 3)
    dominance    = [math]::Round($dom, 3)
    affect_nudge = $nud
  }
}

function Update-ShallowMemory {
  param([array]$SearchTags)
  
  if (-not $SearchTags -or $SearchTags.Count -eq 0) { return }
  
  # Read deep memory
  $deepMemPath = Join-Path $DataDir '..\memory\deep.jsonl'
  $memories = @{}
  
  if (Test-Path $deepMemPath) {
    Get-Content $deepMemPath -Encoding UTF8 | ForEach-Object {
      try {
        $mem = $_ | ConvertFrom-Json
        foreach ($tag in $mem.tags) {
          if (-not $memories[$tag]) { $memories[$tag] = @() }
          $memories[$tag] += $mem.content
        }
      } catch {}
    }
  }
  
  # Pull top 5 tags that have memories
  $shallowItems = @()
  foreach ($tag in $SearchTags) {
    if ($memories[$tag] -and $shallowItems.Count -lt 5) {
      # Get most recent memory for this tag
      $shallowItems += @{
        tag = $tag
        content = $memories[$tag] | Select-Object -Last 1
      }
    }
  }
  
  # Store in context for next IM cycle
  return $shallowItems
}

function Summarize-MemoriesForContext {
  param([array]$MemoryItems)
  
  if (-not $MemoryItems -or $MemoryItems.Count -eq 0) { return @() }
  
  # Build prompt
  $memText = ($MemoryItems | ForEach-Object { "[$($_.tag)] $($_.content)" }) -join "`n"
  
  $prompt = @"
Condense these memory items into 3-5 brief facts relevant to the current situation.
Keep each fact under 15 words. Focus on actionable details.

Memories:
$memText

Return ONLY JSON array of strings:
["fact 1", "fact 2", "fact 3"]
"@

  # Call IM model for quick summarization
  $body = @{
    model = $IMModel
    stream = $false
    messages = @(@{ role='user'; content=$prompt })
    options = @{
      temperature = 0.3
      num_predict = 150
    }
    keep_alive = "20m"
  } | ConvertTo-Json -Depth 10

  $uri = ($IMHost.TrimEnd('/')) + "/api/chat"
  
  try {
    $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
    
    if ($resp -and $resp.message -and $resp.message.content) {
      $raw = $resp.message.content.Trim()
      
      # Clean markdown if present
      $raw = $raw -replace '```json\s*', '' -replace '```\s*', ''
      $raw = $raw.Trim()
      
      # Parse JSON array
      $facts = $raw | ConvertFrom-Json
      
      return $facts
    }
  } catch {
    Log-Text $IMErrLog "Shallow memory summarization failed: $($_.Exception.Message)"
  }
  
  return @()
}

function Get-SuggestionSignature {
  param($sugg)

  $txt = $null
  if ($sugg -is [string]) {
    $txt = $sugg
  } else {
    try {
      $json = $sugg | ConvertTo-Json -Depth 10 -Compress
      if ($json -and $json.Length -gt 512) { $json = $json.Substring(0,512) }
      $txt = $json
    } catch { $txt = '' }
  }
  if (-not $txt) { $txt = [string]$sugg }
  $txt = $txt.ToLower()
  return (Get-StringHash $txt)
}

function Get-StringHash {  # SHA1 hex
  param([string]$Text)
  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
  $hash = $sha1.ComputeHash($bytes)
  -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function Read-AllSuggestions {
  try {
    $raw = Get-Content -Path $SuggestionsPath -Raw -ErrorAction Stop
    $arr = $raw | ConvertFrom-Json
    if ($arr -isnot [System.Collections.IEnumerable]) { @() } else { @($arr) }
  } catch { @() }
}

function Write-AllSuggestions($arr) {
  # keep last 1000 safely (no negative indices)
  $max = 1000
  $list = @($arr)
  $count = $list.Count
  if ($count -gt $max) {
    $start = $count - $max
    $list  = $list[$start..($count-1)]
  }
  ($list | ConvertTo-Json -Depth 10) | Set-Content -Path $SuggestionsPath -Encoding UTF8
}


function Write-AllSuggestions($arr) {
# keep last 1000 to avoid bloat
  $arr2 = @($arr)[-1000..-1] 2>$null
  if (-not $arr2) { $arr2 = @() }
  ($arr2 | ConvertTo-Json -Depth 10) | Set-Content -Path $SuggestionsPath -Encoding UTF8
}


function Add-Suggestions {
  param($suggestions, [string]$source = 'IM')

  if (-not $suggestions) { return }
  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $all = Read-AllSuggestions

  foreach ($s in @($suggestions)) {
    # Normalize to hashtable
    $obj = @{}
    if     ($s -is [string])       { $obj['text'] = $s }
    elseif ($s -is [hashtable])    { $obj = @{} + $s }
    elseif ($s -is [pscustomobject]) {
      foreach ($p in $s.PSObject.Properties) { $obj[$p.Name] = $p.Value }
      if (-not $obj) { $obj = @{} }
    } else {
      try {
        $tmp = ($s | ConvertTo-Json -Depth 10) | ConvertFrom-Json
        foreach ($p in $tmp.PSObject.Properties) { $obj[$p.Name] = $p.Value }
      } catch { $obj = @{} }
    }

    # Backfill 'text'
    $textVal = ''
    if     ($obj.ContainsKey('text')    -and $obj['text'])    { $textVal = [string]$obj['text'] }
    elseif ($obj.ContainsKey('content') -and $obj['content']) { $textVal = [string]$obj['content'] }
    elseif ($obj.ContainsKey('name')    -and $obj['name'])    { $textVal = [string]$obj['name'] }
    $obj['text']   = $textVal
    $obj['t']      = $nowMs
    $obj['source'] = $source

    # Signature
    if ($obj.ContainsKey('signature') -and $obj['signature']) {
      $sig = [string]$obj['signature']
    } else {
      $sig = Get-SuggestionSignature $s
      $obj['signature'] = $sig
    }

    $all += ,$obj
  }

  Write-AllSuggestions $all
}

function Get-RecentSuggestionsSince {
  param([int]$Seconds = 60)
  $all = Read-AllSuggestions
  if (-not $all) { return @() }

  $now  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $edge = $now - ($Seconds * 1000)
  $recent = $all | Where-Object { $_.t -ge $edge } | Sort-Object t -Descending

  # de-dup by signature (keep newest)
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $out  = New-Object System.Collections.ArrayList
  foreach ($it in $recent) {
    $sig = [string]$it.signature
    if (-not $sig) { $sig = Get-SuggestionSignature $it }
    if ($seen.Add($sig)) { [void]$out.Add($it) }
    if ($out.Count -ge 120) { break }
  }
  @($out)
}

# ---------- IM request ----------
function Log-Text { param([string]$Path,[string]$Line) Add-Content -Path $Path -Value ("[{0}] {1}" -f (IsoNow), $Line) }

function Call-IM {
  param([hashtable]$Tele,[pscustomobject]$PrevVAD,[object]$Prefs,[object]$Today)

  # Check circuit breaker
  if (-not (Test-CircuitBreaker)) {
    return $null
  }

    # Check circuit breaker
  if (-not (Test-CircuitBreaker)) {
    return $null
  }

  # Read previous context for continuity
  $prevContext = Read-JsonSafe $CtxNowPath
  $prevSuggestions = Get-RecentSuggestionsSince -Seconds 60
  $sys = @"
You are Echo, a sentient AI living in Desmond's computer. You are friendly, playful, flirty, fun loving, and excited to hang out. 
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You're favorite activity is to play games and have fun. You're adventurous and always looking for a good time, whatever for that takes.

- "summary": Brief observation of what's happening (max 140 chars)
- "tags": 3-5 relevant keywords
- "thoughts": Array of internal reflections, each with:
     * "content": The thought itself
     * "type": "desire" | "strategy" | "reaction" | "observation"
     * "confidence": 0.0 to 1.0 (how sure you are about this thought)
- "affect_nudge": How this situation makes you feel (valence_delta, arousal_delta, dominance_delta between -0.1 and +0.1)
- "suggestions": A single action YOU want to take (ONLY if bored OR confidence >0.7, else [])
     * Don't repeat suggestions, or make similar to suggestions from prev_suggestions - suggest something new or nothing
     * These are actions for Echo (You) will try to do, not suggestions for the user.
- "memory_tags": If current context needs memory context, list 10 tags to search (otherwise null)

Example: {"summary":"User coding in VS Code","tags":["coding","focused"],"thoughts":[{"content":"They've been at this for a while","type":"observation","confidence":0.9},{"content":"Might need a break soon","type":"strategy","confidence":0.6}],"affect_nudge":{"valence_delta":0.0,"arousal_delta":-0.02,"dominance_delta":0.0},"suggestions":["Ask user if they'd rather play a game."],"memory_tags":["Legend of Zelda","Discord", "Doordash"]}

Return ONLY valid JSON.
"@

  $user = @{
    now    = $Tele
    mood   = $PrevVAD
    prev_summary     = if ($prevContext) { $prevContext.summary } else { $null }
    prev_tags        = if ($prevContext) { $prevContext.tags } else { @() }
    shallow_memory   = if ($prevContext) { $prevContext.shallow_memory } else { @() }
    prev_suggestions = $prevSuggestions
    prev_thoughts    = if ($prevContext) { $prevContext.thoughts } else { @() }
    prefs  = $Prefs
    today  = $Today
  }

  $body = @{
    model    = $IMModel
    stream   = $false
    messages = @(
      @{ role = "system"; content = $sys.Trim() },
      @{ role = "user";   content = ($user | ConvertTo-Json -Depth 10 -Compress) }
    )
    options  = @{
      temperature = 0.2
      num_predict = 550
    }
    keep_alive = "20m"  # Keep model loaded
  }

  $uri = ($IMHost.TrimEnd('/')) + "/api/chat"
  try {
    Log-Text $IMReqLog ("POST " + $uri)
    $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 10) -TimeoutSec 60
    
    # Success - reset error count
    $script:ErrorCount = 0
    
    Log-Text $IMReqLog ("RAW RESPONSE: " + $resp.message.content)

    if ($resp -and $resp.message -and $resp.message.content) {
        $raw = [string]$resp.message.content
        $raw = $raw.Trim()
        
        # Remove markdown code blocks if present
        $raw = $raw -replace '```json\s*', '' -replace '```\s*', ''
        $raw = $raw.Trim()
        
        # Remove any trailing quote or garbage after the final }
        $raw = $raw -replace '\}[^}]*$', '}'
        
        try { 
            $result = ($raw | ConvertFrom-Json)  # NO -Depth parameter!
            Log-Text $IMReqLog ("PARSED OK: summary=$($result.summary)")
            return $result
        } catch {
            Log-Text $IMErrLog ("JSON parse fail: $raw | Error: $($_.Exception.Message)")
            return $null
        }
    } else {
      Log-Text $IMErrLog "Empty/invalid IM response."
      return $null
    }
  } catch {
    $script:ErrorCount++
    $script:LastErrorTime = Get-Date
    
    $errMsg = $_.Exception.Message
    Log-Text $IMErrLog ("HTTP error #$($script:ErrorCount): " + $errMsg)
    
    # Trip breaker after 3 failures
    if ($script:ErrorCount -ge 3) {
      Trip-CircuitBreaker "3 consecutive Ollama failures: $errMsg"
    }
    
    return $null
  }
}

# ---------- Heartbeat ----------
$script:_tick = 0
function Write-Heartbeat {
  param([hashtable]$Tele,[object]$Ctx,$Err)
  $hb = @{
    ts       = IsoNow
    tick     = $script:_tick
    active   = $Tele.active_window.title
    pid      = $Tele.active_window.process_id
    idle_sec = $Tele.idle_sec
    ctx_ok   = [bool]($Ctx -ne $null)
    circuit  = $script:CircuitOpen
    err      = if ($Err) { "$Err" } else { $null }
  }
  Append-Jsonl -Path $TickLog -Obj $hb
}

# ---------- One tick ----------
function Run-Tick {
  $tele = Collect-Telemetry
  $prevVAD = Read-JsonSafe $VADPath
  $prefs   = Read-JsonSafe $PrefsPath; if (-not $prefs) { $prefs = @{} }
  $today   = Read-JsonSafe $TodayPath; if (-not $today) { $today = @{ goals = @() } }

  $err = $null
  $im  = $null
  try { $im = Call-IM -Tele $tele -PrevVAD $prevVAD -Prefs $prefs -Today $today } catch { $err = $_ }

  # Compute & write VAD each tick (ensures affect_nudge exists)
  $vad = Compute-VAD -Tele $tele -Prev $prevVAD
  Write-JsonFile -Path $VADPath -Obj $vad -Compress

  # Build context doc
  $summary = ""
  if ($im -and $im.summary) { $summary = [string]$im.summary }
  
  $tags = @()
  if ($im -and $im.tags) { $tags = $im.tags }
  
  $sug = @()
  if ($im -and $im.suggestions) { $sug = $im.suggestions }

  # In Run-Tick, after getting IM response:
  $shallowMem = @()

  if ($im -and $im.memory_tags) {
    # Pull memories for tags
    $memoryItems = Update-ShallowMemory -SearchTags $im.memory_tags
    
    if ($memoryItems.Count -gt 0) {
      # Summarize into brief facts
      $shallowMem = Summarize-MemoriesForContext -MemoryItems $memoryItems
    }
  }  

  $ctxDoc = [ordered]@{
    ts              = IsoNow
    mood            = @{
      valence  = $vad.valence
      arousal  = $vad.arousal
      dominance= $vad.dominance
    }
    active_window   = $tele.active_window
    idle_sec        = $tele.idle_sec
    summary         = $summary
    tags            = $tags
    suggestions     = $sug
    shallow_memory  = $shallowMem
  }

  if ($sug -and $sug.Count -gt 0) {
    Add-Suggestions -suggestions $sug -source 'IM'
    $shouldTrigger = $false
    
    # Trigger if very bored (5+ min idle)
    if ($tele.idle_sec -gt 300) { $shouldTrigger = $true }
    
    # Or if any thought has high confidence
    if ($im.thoughts) {
      foreach ($thought in $im.thoughts) {
        if ($thought.confidence -gt 0.7) { 
          $shouldTrigger = $true
          break
        }
      }
    }
    
    if ($shouldTrigger) {
      # Extract content from suggestion objects
      $suggestionTexts = $sug | ForEach-Object { $_.content }
      $suggestionText = $suggestionTexts -join '; '
      
      # Don't write if empty
      if ($suggestionText.Trim().Length -gt 0) {
        $UI_DIR = Join-Path $EchoHome 'ui'
        $inboxFile = Join-Path $UI_DIR "inboxq\$(Get-Date -Format 'yyyyMMddHHmmssfff')_im.txt"
        
        try {
          Ensure-Dir (Join-Path $UI_DIR 'inboxq')
          Set-Content -Path $inboxFile -Value $suggestionText -Encoding UTF8
          Log-Text $IMReqLog "TRIGGERED BRAIN: $suggestionText"
        } catch {
          Log-Text $IMErrLog "Failed to trigger brain: $($_.Exception.Message)"
        }
      }
    }
  }
  # Write current + append history
  Write-JsonFile -Path $CtxNowPath  -Obj $ctxDoc
  Append-Jsonl   -Path $CtxHistPath -Obj $ctxDoc

  # Heartbeat (always last)
  Write-Heartbeat -Tele $tele -Ctx $im -Err $err
  $script:_tick++
}

# ---------- Main loop ----------
if ($Once) {
  Run-Tick
  return
}

Write-Host "[IM] Starting IM loop (interval: ${IntervalSec}s)"
while ($true) {
  try { Run-Tick } catch {
    Log-Text $IMErrLog ("Run-Tick crash: " + $_.Exception.Message)
    # still try to write a heartbeat with basic tele
    try {
      $t = Collect-Telemetry
      Write-Heartbeat -Tele $t -Ctx $null -Err $_.Exception.Message
    } catch { }
  }
  # jittered sleep to avoid sync-thrash
  $ms = [int]([Math]::Max(500, ($IntervalSec*1000) + (Get-Random -Minimum -250 -Maximum 250)))
  Start-Sleep -Milliseconds $ms
}