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
  [switch]$Once,
  [switch]$EmitPromptFile
)

# ---------- Basics & paths ----------
function IsoNow { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
function Ensure-Dir($p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Append-Jsonl { param([string]$Path,[object]$Obj)
  $line = ($Obj | ConvertTo-Json -Compress)
  Add-Content -Path $Path -Value $line
}

# Fast-path: emit an IM ChatML prompt file for llama.cpp and exit
if ($EmitPromptFile) {
  try { Import-Module "D:\Echo\tools\PromptBuilder.psm1" -Force -DisableNameChecking -ErrorAction SilentlyContinue } catch { }
  $ECHO = $(if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { "D:\Echo" })
  $inbox = Join-Path $ECHO 'ui\inboxq'
  if (-not (Test-Path $inbox)) { New-Item -ItemType Directory -Force -Path $inbox | Out-Null }

  $persona = Get-TextOrEmpty (Join-Path $ECHO 'prompts\persona.im.md')
  $memory  = Get-TextOrEmpty (Join-Path $ECHO 'memory\im-notes.md')
  $system  = 'Inner monologue ONLY. Produce concise thoughts, plans, tags.'
  $user    = 'Observe current state and propose the next nudge as compact JSON.'

  $prompt  = Build-ChatML -System $system -User $user -Memory $memory -Persona $persona

  $ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
  $ImPromptFile = Join-Path $inbox ("im_{0}.txt" -f $ts)
  try {
    [System.IO.File]::WriteAllText($ImPromptFile, $prompt, [System.Text.UTF8Encoding]::new($false))
  } catch {
    $prompt | Set-Content -NoNewline -Encoding UTF8 $ImPromptFile
  }
  Write-Output $ImPromptFile
  return
}

function Write-JsonFile { param([string]$Path,[object]$Obj,[switch]$Compress,[int]$Depth=12)
  $json = $(if ($Compress) { ($Obj | ConvertTo-Json -Compress -Depth $Depth) } else { ($Obj | ConvertTo-Json -Depth $Depth) })
  Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Read-JsonSafe { param([string]$Path)
  if (Test-Path $Path) {
    try { return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  } else { return $null }
}

# Load a small window of recent chat history for IM context
function Load-ConversationHistoryIM {
  param([string]$HomeDir, [int]$Max = 12)
  $histPath = Join-Path $HomeDir 'state\conversation_history.jsonl'
  $messages = @()
  try {
    if (Test-Path -LiteralPath $histPath) {
      $lines = Get-Content -LiteralPath $histPath -Encoding UTF8 | Select-Object -Last $Max
      foreach ($ln in $lines) {
        try {
          $obj = $ln | ConvertFrom-Json
          if ($obj.role -and $obj.content) { $messages += @{ role=$obj.role; content=$obj.content } }
        } catch { }
      }
    }
  } catch { }
  return ,$messages
}

# ---------- JSON helpers (robust parsing for llama.cpp outputs) ----------
function Remove-CodeFences { param([string]$Text)
  if (-not $Text) { return '' }
  $t = $Text.Trim()
  $t = $t -replace "^```(?:json)?\s*", ''
  $t = $t -replace "\s*```\s*$", ''
  return $t.Trim()
}

function Try-ParseJsonStrict { param([string]$Text)
  if (-not $Text) { return $null }
  $t = Remove-CodeFences $Text
  # Trim to outermost braces if present
  $start = $t.IndexOf('{')
  $end   = $t.LastIndexOf('}')
  if ($start -ge 0 -and $end -gt $start) { $t = $t.Substring($start, ($end - $start + 1)) }
  try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Get-RegexLastValue {
  param([string]$Text,[string]$Pattern)
  if (-not $Text) { return $null }
  $rx = New-Object System.Text.RegularExpressions.Regex($Pattern, 'Singleline, IgnoreCase')
  $m = $rx.Matches($Text)
  if ($m.Count -gt 0) { return $m[$m.Count-1].Groups[1].Value }
  return $null
}

function Parse-ImJsonLoose {
  param([string]$Text)
  if (-not $Text) { return $null }
  $t = Remove-CodeFences $Text
  # Pull fields by regex even if braces are missing
  $summary = Get-RegexLastValue $t '"summary"\s*:\s*"([^"]*)"'
  $tagsStr = Get-RegexLastValue $t '"tags"\s*:\s*(\[[^\]]*\])'
  $thoughtsStr = Get-RegexLastValue $t '"thoughts"\s*:\s*(\[[\s\S]*?\])'
  $affStr = Get-RegexLastValue $t '"affect_nud(?:ge|e)"\s*:\s*(\{[\s\S]*?\})'
  $sugStr = Get-RegexLastValue $t '"suggestions"\s*:\s*(\[[\s\S]*?\])'
  $memTagsStr = Get-RegexLastValue $t '"memory_tags"\s*:\s*(\[[\s\S]*?\]|null)'

  $tags = @(); if ($tagsStr) { try { $tags = @((ConvertFrom-Json $tagsStr)) } catch { $tags = @() } }
  $thoughts = @(); if ($thoughtsStr) { try { $thoughts = @((ConvertFrom-Json $thoughtsStr)) } catch { $thoughts = @() } }
  $sug = @(); if ($sugStr) { try { $sug = @((ConvertFrom-Json $sugStr)) } catch { $sug = @() } }
  $mem = $null; if ($memTagsStr) { try { $mem = (ConvertFrom-Json $memTagsStr) } catch { $mem = $null } }
  $aff = $null; if ($affStr) { try { $aff = (ConvertFrom-Json $affStr) } catch { $aff = $null } }

  if (-not $summary -and $tags.Count -eq 0 -and $thoughts.Count -eq 0 -and $sug.Count -eq 0 -and -not $aff) { return $null }
  return [pscustomobject]@{
    summary      = $(if ($summary) { [string]$summary } else { '' })
    tags         = $tags
    thoughts     = $thoughts
    affect_nudge = $aff
    suggestions  = $sug
    memory_tags  = $mem
  }
}

function Parse-JsonArrayLoose { param([string]$Text)
  if (-not $Text) { return @() }
  $strict = Try-ParseJsonStrict $Text
  if ($strict -is [System.Collections.IEnumerable] -and $strict -isnot [string]) { return ,@($strict) }
  $t = Remove-CodeFences $Text
  $arrStr = Get-RegexLastValue $t '(\[[\s\S]*\])'
  if ($arrStr) { try { return ,@((ConvertFrom-Json $arrStr)) } catch { } }
  # Fallback: lines starting with - or quoted lines
  $lines = ($t -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  $items = @()
  foreach ($ln in $lines) {
    if ($ln -match '^\-\s*(.+)$') { $items += $Matches[1].Trim() }
    elseif ($ln -match '^"([^"]+)"\s*,?$') { $items += $Matches[1] }
  }
  return ,$items
}

# ---------- Home & files ----------
$script:_phase = 'init'
$EchoHome = $(if ($env:ECHO_HOME -and (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME } else { $PSScriptRoot })
$StateDir = Join-Path $EchoHome 'state'
$LogsDir  = Join-Path $EchoHome 'logs'
$DataDir  = Join-Path $EchoHome 'data'
Ensure-Dir $StateDir; Ensure-Dir $LogsDir; Ensure-Dir $DataDir

# UI bus (outbox) for visibility
$UiDir = Join-Path $EchoHome 'ui'
Ensure-Dir $UiDir
$OutboxPath = Join-Path $UiDir 'outbox.jsonl'
if (-not (Test-Path -LiteralPath $OutboxPath)) { New-Item -ItemType File -Force -Path $OutboxPath | Out-Null }

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
$IMHost = $(if ($env:IM_HOST -and $env:IM_HOST.Trim()) { 
    $env:IM_HOST 
} elseif ($env:OLLAMA_HOST -and $env:OLLAMA_HOST.Trim()) { 
    $env:OLLAMA_HOST 
} else { 
    'http://127.0.0.1:11434' 
})

$IMModel = 'dolphin-phi:2.7b'
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

# ---------- Activity hint ----------
function Get-ActiveHint {
  param([hashtable]$Tele)
  try {
    $title = ('' + $Tele.active_window.title).ToLower()
    $proc  = ('' + $Tele.active_window.process).ToLower()
  } catch {
    return ''
  }
  if ($proc -match 'steam' -or $title -match 'steam') { return 'gaming/steam' }
  if ($title -match 'nvidia' -or $proc -match 'nvidia') { return 'graphics_settings' }
  if ($proc -match 'code|devenv|idea|pycharm|notepad\+\+|sublime|atom' -or $title -match 'visual studio|vscode|code -') { return 'coding' }
  if ($proc -match 'powershell|cmd|wt|terminal') { return 'terminal' }
  if ($proc -match 'chrome|edge|firefox|brave|vivaldi') { return 'browsing' }
  if ($title -match 'discord' -or $proc -match 'discord') { return 'chat' }
  return ''
}

# ---------- Fresh summary/tag helpers ----------
function New-QuickSummary {
  param([hashtable]$Tele)
  try {
    $t = ''
    if ($Tele -and $Tele.active_window -and $Tele.active_window.title) { $t = [string]$Tele.active_window.title }
    $p = ''
    if ($Tele -and $Tele.active_window -and $Tele.active_window.process) { $p = [string]$Tele.active_window.process }
    if ($t -and $p) { return ("Active in {0} ({1})" -f $t, $p) }
    elseif ($t) { return ("Active in {0}" -f $t) }
    else { return 'Observing system state and recent activity' }
  } catch { return 'Observing system state and recent activity' }
}

function New-TagsFromActive {
  param([hashtable]$Tele)
  $tags = @()
  try {
    if ($Tele -and $Tele.active_window) {
      $t = ''+ $Tele.active_window.title
      $p = ''+ $Tele.active_window.process
      $words = @()
      if ($t) { $words += ($t -replace '[^A-Za-z0-9 ]',' ' -split '\s+' | Where-Object { $_ -and $_.Length -ge 3 }) }
      if ($p) { $words += ($p) }
      $words = @($words | Select-Object -Unique)
      if ($words.Count -gt 0) { $tags += ($words | Select-Object -First 3) }
    }
  } catch {}
  if ($tags.Count -eq 0) { $tags = @('status','active','system') }
  ,$tags
}

# ---------- VAD + mood ----------
function Compute-VAD {
  param([hashtable]$Tele, [pscustomobject]$Prev)
  
  $hour = (Get-Date).Hour
  $idle = $(if ($Tele.idle_sec -ne $null) { [double]$Tele.idle_sec } else { 0.0 })
  
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
    valence_delta   = $(if ($val -lt 0.35) { +0.08 } elseif ($val -gt 0.8) { -0.04 } else { 0.0 })
    arousal_delta   = $(if ($aro -gt 0.75) { -0.1 } elseif ($aro -lt 0.25) { +0.08 } else { 0.0 })
    dominance_delta = $(if ($dom -lt 0.35) { +0.06 } elseif ($dom -gt 0.85) { -0.04 } else { 0.0 })
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
  # Default to llama.cpp unless explicitly disabled via env
  $useLlama = $true
  if ($env:ECHO_IM_USE_LLAMA_CPP -and ($env:ECHO_IM_USE_LLAMA_CPP -match '^(0|false|no)$')) { $useLlama = $false }
  elseif ($env:ECHO_USE_LLAMA_CPP -and ($env:ECHO_USE_LLAMA_CPP -match '^(0|false|no)$')) { $useLlama = $false }

  if ($useLlama) {
    try {
      $parts = @()
      $parts += "<|im_start|>user`n$prompt<|im_end|>"
      # Prime JSON array generation
      $parts += "<|im_start|>assistant`n["
      $chatml = ($parts -join "`n")
      $logs = Join-Path $EchoHome 'logs'; Ensure-Dir $logs
      $pf = Join-Path $logs ("im_summarize_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
      [System.IO.File]::WriteAllText($pf, $chatml, [System.Text.UTF8Encoding]::new($false))
      $runner = Join-Path $EchoHome 'tools\Start-LocalLLM.ps1'
      # Resolve model path (prefer IM-specific env, then general, else default small model under Echo/models)
      $defaultModel = Join-Path $EchoHome 'models\model-Q3_K_M.gguf'
      $modelPath = $(if ($env:ECHO_IM_LLAMACPP_MODEL -and (Test-Path $env:ECHO_IM_LLAMACPP_MODEL)) { $env:ECHO_IM_LLAMACPP_MODEL } elseif ($env:ECHO_LLAMACPP_MODEL -and (Test-Path $env:ECHO_LLAMACPP_MODEL)) { $env:ECHO_LLAMACPP_MODEL } else { $defaultModel })
      $llamaExe  = $(if ($env:LLAMA_EXE -and (Test-Path $env:LLAMA_EXE)) { $env:LLAMA_EXE } else { 'D:\llama-cpp\llama-cli.exe' })
      $gpuLayers = 40; if ($env:ECHO_IM_GPU_LAYERS -and $env:ECHO_IM_GPU_LAYERS.Trim()) { try { $gpuLayers = [int]$env:ECHO_IM_GPU_LAYERS } catch {} } elseif ($env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { try { $gpuLayers = [int]$env:ECHO_LLAMA_GPU_LAYERS } catch {} }
      $t0 = Get-Date
      $raw = powershell -NoProfile -ExecutionPolicy Bypass -File $runner -PromptFile $pf -ModelPath $modelPath -LlamaExe $llamaExe -GpuLayers $gpuLayers -Temp 0.2 -MaxTokens 220 -FlashAttn | Out-String
      $raw = $raw.Trim()
      $raw = $raw -replace '```json\s*', '' -replace '```\s*', ''
      $raw = $raw.Trim()
      $facts = $raw | ConvertFrom-Json
      try {
        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
        $outbox = Join-Path $EchoHome 'ui\outbox.jsonl'
        if (Test-Path -LiteralPath $outbox) {
          $evt = @{ ts=(Get-Date).ToString('o'); kind='system'; channel='trace'; stage='im.summarize'; data=@{ ok=$true; ms=$ms; backend='llama.cpp' } } | ConvertTo-Json -Compress
          Add-Content -LiteralPath $outbox -Value $evt -Encoding UTF8
        }
      } catch { }
      return $facts
    } catch {
      Log-Text $IMErrLog ("IM summarize via llama.cpp failed: " + $_.Exception.Message)
      # fall through to Ollama path
    }
  }

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
    $t0 = Get-Date
    $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
    
    if ($resp -and $resp.message -and $resp.message.content) {
      $raw = $resp.message.content.Trim()
      # Parse robustly
      $facts = Parse-JsonArrayLoose $raw
      # timing log to outbox
      try {
        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
        $outbox = Join-Path $EchoHome 'ui\outbox.jsonl'
        if (Test-Path -LiteralPath $outbox) {
          $evt = @{ ts=(Get-Date).ToString('o'); kind='system'; channel='trace'; stage='im.summarize'; data=@{ ok=$true; ms=$ms } } | ConvertTo-Json -Compress
          Add-Content -LiteralPath $outbox -Value $evt -Encoding UTF8
        }
      } catch { }
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
You are Echo's inner monologue. You think silently about what is happening right now on Desmond's computer, how you feel, and what you want to do next.

TASK
- Produce exactly one JSON object describing the current situation as you perceive it (inner thoughts), grounded in the current context.

REQUIRED KEYS (exactly these keys, no duplicates):
- "summary": string (<=160 chars). Based on now.active_window.title/process and recent_conversation what do I think is happening? Do not just say what the window is, make an educated guess on what is happening on that window.
- "tags": 3–5 short keywords about the current situation (e.g., ["steam","browsing","relaxed"]).
- "thoughts": string (~400 chars). What do you think about whats going on? What are your desires, feelings, ideas, suggestions, beliefs about what is happening?
- "affect_nudge": {"valence_delta": -0.1..0.1, "arousal_delta": -0.1..0.1, "dominance_delta": -0.1..0.1} balancing mood.
- "suggestions": array Only include if strongly relevant or idle/bored; this is an action YOU want to take. start suggestions with "I should..."
- "memory_tags": array of up to 10 strings or null for any useful long-term tags.

INPUTS
- You receive: now (telemetry), mood (vad), prefs/today, active_window, recent_conversation, and helper hints like active_hint, process_name.

OUTPUT RULES
- Output EXACTLY ONE JSON object. No prose, no extra lines.
- Do NOT copy prev_summary or prev_tags; recompute from current inputs.
- Only mention coding when active_window/process clearly indicates an IDE/terminal or recent_conversation is about code. If the app is Steam/NVIDIA/Discord/browsers, anchor to that context instead.
- Describe what you see (window title/process) and your likely next nudge.

Return ONLY JSON.
"@

  $user = @{
    now    = $Tele
    mood   = $PrevVAD
    active_window   = $Tele.active_window
    prev_summary     = $(if ($prevContext) { $prevContext.summary } else { $null })
    prev_tags        = $(if ($prevContext) { $prevContext.tags } else { @() })
    shallow_memory   = $(if ($prevContext) { $prevContext.shallow_memory } else { @() })
    prev_suggestions = $prevSuggestions
    prev_thoughts    = $(if ($prevContext) { $prevContext.thoughts } else { @() })
    prefs  = $Prefs
    today  = $Today
    recent_conversation = (Load-ConversationHistoryIM -HomeDir $EchoHome -Max 12)
    active_app       = $Tele.active_window.title
    process_name     = $Tele.active_window.process
    active_hint      = (Get-ActiveHint -Tele $Tele)
  }

  # Prefer llama.cpp runner by default (opt-out via env)
  $useLlama = $true
  if ($env:ECHO_IM_USE_LLAMA_CPP -and ($env:ECHO_IM_USE_LLAMA_CPP -match '^(0|false|no)$')) { $useLlama = $false }
  elseif ($env:ECHO_USE_LLAMA_CPP -and ($env:ECHO_USE_LLAMA_CPP -match '^(0|false|no)$')) { $useLlama = $false }

  if ($useLlama) {
    try {
      $sysText = $sys.Trim()
      $userJson = ($user | ConvertTo-Json -Depth 10 -Compress)
      $parts = @()
      $parts += "<|im_start|>system`n$sysText<|im_end|>"
      $parts += "<|im_start|>user`n$userJson<|im_end|>"
      # Prime JSON object generation for better compliance
      $parts += "<|im_start|>assistant`n{"
      $chatml = ($parts -join "`n")

      $logs = Join-Path $EchoHome 'logs'; Ensure-Dir $logs
      $pf = Join-Path $logs ("im_chat_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
      [System.IO.File]::WriteAllText($pf, $chatml, [System.Text.UTF8Encoding]::new($false))

      $runner = Join-Path $EchoHome 'tools\Start-LocalLLM.ps1'
      # Resolve model path for IM (small default), allow env overrides
      $defaultModel = Join-Path $EchoHome 'models\model-Q3_K_M.gguf'
      $modelPath = $(if ($env:ECHO_IM_LLAMACPP_MODEL -and (Test-Path $env:ECHO_IM_LLAMACPP_MODEL)) { $env:ECHO_IM_LLAMACPP_MODEL } elseif ($env:ECHO_LLAMACPP_MODEL -and (Test-Path $env:ECHO_LLAMACPP_MODEL)) { $env:ECHO_LLAMACPP_MODEL } else { $defaultModel })
      $llamaExe  = $(if ($env:LLAMA_EXE -and (Test-Path $env:LLAMA_EXE)) { $env:LLAMA_EXE } else { 'D:\llama-cpp\llama-cli.exe' })
      $gpuLayers = 40; if ($env:ECHO_IM_GPU_LAYERS -and $env:ECHO_IM_GPU_LAYERS.Trim()) { try { $gpuLayers = [int]$env:ECHO_IM_GPU_LAYERS } catch {} } elseif ($env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { try { $gpuLayers = [int]$env:ECHO_LLAMA_GPU_LAYERS } catch {} }
      $t0 = Get-Date
      $raw = powershell -NoProfile -ExecutionPolicy Bypass -File $runner -PromptFile $pf -ModelPath $modelPath -LlamaExe $llamaExe -GpuLayers $gpuLayers -Temp 0.2 -MaxTokens 400 -FlashAttn | Out-String
      $raw = $raw.Trim()
      # Remove markdown code blocks if present
      $raw = $raw -replace '```json\s*', '' -replace '```\s*', ''
      $raw = $raw.Trim()
      # Remove any trailing after final }
      $raw = $raw -replace '\}[^}]*$', '}'

      try {
        $result = Try-ParseJsonStrict $raw
        if (-not $result) { $result = Parse-ImJsonLoose $raw }
        # timing log
        try {
          $ms = [int]((Get-Date) - $t0).TotalMilliseconds
          $outbox = Join-Path $EchoHome 'ui\outbox.jsonl'
          if (Test-Path -LiteralPath $outbox) {
            $evt = @{ ts=(Get-Date).ToString('o'); kind='system'; channel='trace'; stage='im.model'; data=@{ ok=$true; ms=$ms; backend='llama.cpp' } } | ConvertTo-Json -Compress
            Add-Content -LiteralPath $outbox -Value $evt -Encoding UTF8
          }
        } catch { }
        $script:ErrorCount = 0
        return $result
      } catch {
        Log-Text $IMErrLog ("llama.cpp JSON parse fail: $raw | Error: " + $_.Exception.Message)
        # fall through to Ollama path
      }
    } catch {
      Log-Text $IMErrLog ("llama.cpp IM error: " + $_.Exception.Message)
      # fall through to Ollama path
    }
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
    $t0 = Get-Date
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
            $result = Try-ParseJsonStrict $raw
            if (-not $result) { $result = Parse-ImJsonLoose $raw }
            Log-Text $IMReqLog ("PARSED OK: summary=$($result.summary)")
            try {
              $ms = [int]((Get-Date) - $t0).TotalMilliseconds
              $outbox = Join-Path $EchoHome 'ui\outbox.jsonl'
              if (Test-Path -LiteralPath $outbox) {
                $evt = @{ ts=(Get-Date).ToString('o'); kind='system'; channel='trace'; stage='im.model'; data=@{ ok=$true; ms=$ms } } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $outbox -Value $evt -Encoding UTF8
              }
            } catch { }
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
    try {
      $ms = [int]((Get-Date) - $t0).TotalMilliseconds
      $outbox = Join-Path $EchoHome 'ui\outbox.jsonl'
      if (Test-Path -LiteralPath $outbox) {
        $evt = @{ ts=(Get-Date).ToString('o'); kind='system'; channel='trace'; stage='im.model'; data=@{ ok=$false; ms=$ms; error=$errMsg } } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $outbox -Value $evt -Encoding UTF8
      }
    } catch { }

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
  $errMsg = $null; $errDetail = $null
  if ($Err) {
    try {
      if ($Err -is [System.Management.Automation.ErrorRecord]) {
        $er = [System.Management.Automation.ErrorRecord]$Err
        $inv = $er.InvocationInfo
        $errMsg = "$er"
        $detail = [ordered]@{}
        if ($inv) {
          $detail.script = $inv.ScriptName
          $detail.line   = $inv.ScriptLineNumber
          $detail.char   = $inv.OffsetInLine
          $detail.pos    = ($inv.PositionMessage)
        }
        if ($er.FullyQualifiedErrorId) { $detail.fqid = $er.FullyQualifiedErrorId }
        if ($er.CategoryInfo)          { $detail.category = "$($er.CategoryInfo)" }
        if ($er.Exception)             { $detail.exception = $er.Exception.GetType().FullName }
        if ($global:Error[0] -and $global:Error[0].ScriptStackTrace) { $detail.stack = $global:Error[0].ScriptStackTrace }
        $errDetail = $detail
      } elseif ($Err -is [System.Exception]) {
        $ex = [System.Exception]$Err
        $errMsg = $ex.Message
        $errDetail = @{ exception = $ex.GetType().FullName; stack = $ex.StackTrace }
      } else {
        $errMsg = "$Err"
      }
    } catch { $errMsg = "$Err" }
  }
  $hb = @{
    ts       = IsoNow
    tick     = $script:_tick
    active   = $Tele.active_window.title
    pid      = $Tele.active_window.process_id
    idle_sec = $Tele.idle_sec
    ctx_ok   = [bool]($Ctx -ne $null)
    circuit  = $script:CircuitOpen
    phase    = $script:_phase
    err      = $errMsg
    err_detail = $errDetail
  }
  Append-Jsonl -Path $TickLog -Obj $hb
  # Also mirror a lightweight heartbeat into the outbox bus for easy visibility
  try {
    Append-Jsonl -Path $OutboxPath -Obj @{ kind='system'; channel='im'; event='heartbeat'; tick=$script:_tick; idle=$Tele.idle_sec; active=$Tele.active_window.title }
  } catch { }
}

# ---------- One tick ----------
function Run-Tick {
  $script:_phase = 'collect'
  $tele = Collect-Telemetry
  $prevVAD = Read-JsonSafe $VADPath
  $prefs   = Read-JsonSafe $PrefsPath; if (-not $prefs) { $prefs = @{} }
  $today   = Read-JsonSafe $TodayPath; if (-not $today) { $today = @{ goals = @() } }

  $err = $null
  $im  = $null
  $script:_phase = 'call-im'
  try { $im = Call-IM -Tele $tele -PrevVAD $prevVAD -Prefs $prefs -Today $today } catch { $err = $_ }

  # Detect stale repetition (same summary as previous while active window changed) and refresh
  try {
    $prevCtx = Read-JsonSafe $CtxNowPath
    $prevSum = if ($prevCtx -and $prevCtx.summary) { ('' + $prevCtx.summary).Trim() } else { '' }
    $newSum  = if ($im -and $im.summary)        { ('' + $im.summary).Trim() } else { '' }
    $prevWin = if ($prevCtx -and $prevCtx.active_window -and $prevCtx.active_window.title) { '' + $prevCtx.active_window.title } else { '' }
    $currWin = if ($tele -and $tele.active_window -and $tele.active_window.title) { '' + $tele.active_window.title } else { '' }
    $activeChanged = ($prevWin -ne $currWin) -and ($currWin -ne '')
    if ($im -and $newSum -and $prevSum -and ($newSum -eq $prevSum) -and $activeChanged) {
      $old = $newSum
      $fresh = New-QuickSummary -Tele $tele
      $im.summary = $fresh
      # Tags refresh only if identical to prev tags too
      $tagsEqual = $false
      try {
        $a = @(); if ($im.tags) { $a = @($im.tags) }
        $b = @(); if ($prevCtx -and $prevCtx.tags) { $b = @($prevCtx.tags) }
        $tagsEqual = ($a.Count -eq $b.Count) -and (@(0..($a.Count-1) | Where-Object { ''+$a[$_] -ne ''+$b[$_] }).Count -eq 0)
      } catch { $tagsEqual = $false }
      if ($tagsEqual -or -not ($im.tags) -or $im.tags.Count -eq 0) { $im.tags = (New-TagsFromActive -Tele $tele) }
      try { Append-Jsonl -Path $OutboxPath -Obj @{ kind='system'; channel='trace'; stage='im.refresh'; data=@{ reason='stale_summary'; prev=$old; curr=$im.summary; win=$currWin } } } catch {}
    }
  } catch { }

  # Compute & write VAD each tick (ensures affect_nudge exists)
  $script:_phase = 'vad'
  $vad = Compute-VAD -Tele $tele -Prev $prevVAD
  Write-JsonFile -Path $VADPath -Obj $vad -Compress

  # Build context doc
  $script:_phase = 'ctx'
  $summary = ""
  if ($im -and $im.summary) { $summary = [string]$im.summary }
  
  $tags = @()
  if ($im -and $im.tags) { $tags = $im.tags }

  # Ensure we always have a current summary/tags, even if model failed or repeated
  if (-not $summary -or ($summary.Trim().Length -eq 0)) {
    $summary = New-QuickSummary -Tele $tele
    try { Append-Jsonl -Path $OutboxPath -Obj @{ kind='system'; channel='trace'; stage='im.refresh'; data=@{ reason='no_summary'; win=$tele.active_window.title } } } catch { }
  }
  if (-not $tags -or $tags.Count -eq 0) {
    $tags = New-TagsFromActive -Tele $tele
  }

  # Guard against mismatched content: if model says "coding" but active hint isn't coding/terminal, refresh
  try {
    $hint = Get-ActiveHint -Tele $tele
    $isCodingHint = ($hint -eq 'coding' -or $hint -eq 'terminal')
    $summaryLower = ('' + $summary).ToLower()
    $hasCodingWords = ($summaryLower -match '\bcoding\b|\bprogramming\b|vs code|visual studio') -or (@($tags | Where-Object { (''+$_).ToLower() -match 'coding|programming|code' }).Count -gt 0)
    if (-not $isCodingHint -and $hasCodingWords) {
      $old = $summary
      $summary = New-QuickSummary -Tele $tele
      $tags = New-TagsFromActive -Tele $tele
      try { Append-Jsonl -Path $OutboxPath -Obj @{ kind='system'; channel='trace'; stage='im.refresh'; data=@{ reason='mismatch_hint'; prev=$old; curr=$summary; hint=$hint } } } catch { }
    }
  } catch { }
  
  $sug = @()
  if ($im -and $im.suggestions) { $sug = $im.suggestions }

  $thoughts = @()
  if ($im -and $im.thoughts) { $thoughts = $im.thoughts }

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
    thoughts        = $thoughts
    suggestions     = $sug
    shallow_memory  = $shallowMem
  }

  if ($sug -and $sug.Count -gt 0) {
    $script:_phase = 'suggestions'
    Add-Suggestions -suggestions $sug -source 'IM'

    # --- Suggestion gating helpers ---
    function Normalize-Text([string]$t){
      if (-not $t) { return '' }
      ($t.ToLower() -replace '[^a-z0-9\s]', ' ' -replace '\s+', ' ').Trim()
    }
    function Token-Set([string]$t){
      if (-not $t) { return @() }
      $stop = @('the','a','an','of','to','and','or','for','in','on','with','about','like','this','that','it','we','you')
      $norm = Normalize-Text $t
      @($norm.Split(' ') | Where-Object { $_ -and ($stop -notcontains $_) } | Select-Object -Unique)
    }
    function Is-Novel([string]$t, [array]$recent){
      $A = Token-Set $t; if ($A.Count -eq 0) { return $false }
      foreach ($r in $recent) {
        $B = Token-Set $(if ($r.content) { $r.content } else { "$r" })
        if ($B.Count -eq 0) { continue }
        $inter = @($A | Where-Object { $B -contains $_ })
        $union = @($A + $B | Select-Object -Unique)
        $sim = $(if ($union.Count -gt 0) { [double]$inter.Count / [double]$union.Count } else { 0.0 })
        if ($sim -ge 0.6) { return $false }
      }
      return $true
    }

    # Read a few recent suggestions (10 min)
    $recent = Get-RecentSuggestionsSince -Seconds 600
    $cooldownSec = 240
    if ($env:ECHO_IM_SUGGEST_COOLDOWN_SEC -and $env:ECHO_IM_SUGGEST_COOLDOWN_SEC.Trim()) {
      try { $cooldownSec = [int]$env:ECHO_IM_SUGGEST_COOLDOWN_SEC } catch { $cooldownSec = 240 }
    }

    # Rate limit via last_suggestion.json
    $LastTrigPath = Join-Path $StateDir 'last_suggestion.json'
    $lastOk = $null
    if (Test-Path $LastTrigPath) {
      try { $lastOk = Get-Content $LastTrigPath -Raw | ConvertFrom-Json } catch { $lastOk = $null }
    }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $elapsedOkMs = $(if ($lastOk -and $lastOk.t) { $nowMs - [long]$lastOk.t } else { 999999999 })

    # Compute a single candidate text
    $suggestionTexts = @()
    foreach ($s in $sug) { if ($s) { $suggestionTexts += $(if ($s.content) { "$($s.content)" } else { "$s" }) } }
    $candidate = ($suggestionTexts | Where-Object { ($_ -is [string]) -and $_.Trim().Length -gt 6 } | Select-Object -First 1)

    $shouldTrigger = $false
    if ($candidate) {
      # Base conditions: idle or strong thought
      if ($tele.idle_sec -ge 420) { $shouldTrigger = $true }
      elseif ($im.thoughts) {
        foreach ($thought in $im.thoughts) { if ($thought.confidence -gt 0.85) { $shouldTrigger = $true; break } }
      }
      # Novelty
      if ($shouldTrigger) { if (-not (Is-Novel $candidate $recent)) { $shouldTrigger = $false } }
      # Cooldown
      if ($shouldTrigger) { if ($elapsedOkMs -lt ($cooldownSec * 1000)) { $shouldTrigger = $false } }
    }

    # If allowed by env and gating passed, trigger
    $allowActivate = -not ($env:ECHO_IM_ACTIVATE -and $env:ECHO_IM_ACTIVATE -match '^(0|false|no)$')
    if ($allowActivate -and $shouldTrigger -and $candidate) {
      $UI_DIR = Join-Path $EchoHome 'ui'
      $inboxFile = Join-Path $UI_DIR ("inboxq\{0}_im.txt" -f (Get-Date -Format 'yyyyMMddHHmmssfff'))
      try {
        Ensure-Dir (Join-Path $UI_DIR 'inboxq')
        Set-Content -Path $inboxFile -Value $candidate -Encoding UTF8
        Log-Text $IMReqLog ("TRIGGERED BRAIN: " + $candidate)
        # Update last ok
        $payload = @{ t = $nowMs; text = $candidate } | ConvertTo-Json -Compress
        Set-Content -Path $LastTrigPath -Value $payload -Encoding UTF8
      } catch {
        Log-Text $IMErrLog ("Failed to trigger brain: " + $_.Exception.Message)
      }
    }
  }
  # Write current + append history
  $script:_phase = 'persist'
  try {
    Write-JsonFile -Path $CtxNowPath  -Obj $ctxDoc -Depth 12
    Append-Jsonl   -Path $CtxHistPath -Obj $ctxDoc
    # Also persist shallow memory to a dedicated file compatible with Start-Echo reader
    try {
      $shPath = Join-Path $StateDir 'shallow_memory.json'
      $shDoc = @{ ts = IsoNow; items = $shallowMem }
      Write-JsonFile -Path $shPath -Obj $shDoc -Depth 10
    } catch { }
    # Emit a small trace for verification
    try { Append-Jsonl -Path $OutboxPath -Obj @{ kind='system'; channel='trace'; stage='im.ctx'; data=@{ summary=$summary; tags=$tags } } } catch { }
  } catch {
    try { Append-Jsonl -Path $OutboxPath -Obj @{ kind='system'; channel='trace'; stage='im.ctx'; data=@{ error=$_.Exception.Message } } } catch { }
  }

  # Heartbeat (always last)
  $script:_phase = 'heartbeat'
  Write-Heartbeat -Tele $tele -Ctx $im -Err $err
  $script:_tick++
}

# ---------- Main loop ----------
if ($Once) {
  Run-Tick
  return
}

Write-Host "[IM] Starting IM loop (interval: ${IntervalSec}s)"
try {
  Append-Jsonl -Path $OutboxPath -Obj @{ kind='system'; channel='im'; event='boot'; home=$EchoHome; interval=$IntervalSec }
} catch { }

while ($true) {
  $script:_phase = 'loop-start'
  try {
    Run-Tick
  } catch {
    try {
      $t = Collect-Telemetry
      Write-Heartbeat -Tele $t -Ctx $null -Err $_
    } catch { }
  }
  $ms = [int]([Math]::Max(500, ($IntervalSec*1000) + (Get-Random -Minimum -250 -Maximum 250)))
  $script:_phase = 'loop-sleep'
  Start-Sleep -Milliseconds $ms
}
