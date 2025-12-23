[CmdletBinding()]
param(
  [string]$MainServer,
  [string]$SmallServer
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'

try { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $ScriptRoot = Get-Location }
$coreModule = Join-Path $ScriptRoot 'tools\Echo.Core.psm1'
if (Test-Path -LiteralPath $coreModule) { Import-Module $coreModule -Force -DisableNameChecking }

function Log([string]$msg)  { [Console]::WriteLine("[Echo] $msg") }
function Warn([string]$msg) { [Console]::WriteLine("[Echo][WARN] $msg") }

$paths = Get-EchoPaths -Home $ScriptRoot
$paths.ConversationHistory = Join-Path $paths.State 'conversation_history.jsonl'
$paths.voice_inbox = "D:\Echo\ui\inbox_voice"
Ensure-EchoPaths $paths
$env:ECHO_HOME = $paths.Home
# ThinkingLoop.ps1 defaults to $env:ECHO_ROOT; keep it in sync with our resolved home.
$env:ECHO_ROOT = $paths.Home

if (-not $MainServer -or -not $MainServer.Trim())   { $MainServer  = if ($env:ECHO_MAIN_SERVER) { $env:ECHO_MAIN_SERVER } else { 'http://127.0.0.1:8080' } }
if (-not $SmallServer -or -not $SmallServer.Trim()) { $SmallServer = if ($env:ECHO_SMALL_SERVER){ $env:ECHO_SMALL_SERVER } else { 'http://127.0.0.1:8081' } }
$mainModelName  = if ($env:ECHO_MAIN_MODEL_NAME)  { $env:ECHO_MAIN_MODEL_NAME }  else { 'main' }
$smallModelName = if ($env:ECHO_SMALL_MODEL_NAME) { $env:ECHO_SMALL_MODEL_NAME } else { 'small' }

$script:InboxPath = if ($paths.Inbox) { $paths.Inbox } else { Join-Path $paths.UI 'inboxq' }
if (-not (Test-Path -LiteralPath $script:InboxPath)) { New-Item -ItemType Directory -Force -Path $script:InboxPath | Out-Null }
$script:SeenInbox = New-Object 'System.Collections.Generic.Dictionary[string,long]'  # track last write to allow rewrites of same file name
$script:LastPingLines = 0
$script:InboxWarnedMissing = $false
$script:LogRoot = $paths.Logs
$script:LastHeartbeat = Get-Date
$script:LastWakeupCheck = [DateTime]::MinValue  # rate limit wakeup file reads
$thinkingFlag = Join-Path $paths.State 'thinking.flag'

function Remove-CodeFences([string]$t) {
  if (-not $t) { return "" }
  $txt = $t.Trim()
  $txt = $txt -replace '^```(?:json)?\s*',''
  $txt = $txt -replace '\s*```\s*$',''
  return $txt.Trim()
}

function Get-JsonFromMixedResponse([string]$text) {
  if (-not $text) { return $null }
  
  # 1. Clean Markdown code blocks first
  $clean = $text -replace '```json', '' -replace '```', ''
  
  # 2. Extract the first { ... } block using Regex (Non-greedy)
  # This ignores the "Visual Description" text surrounding the JSON
  if ($clean -match '(?s)(\{.*?\})') {
      $jsonCandidate = $matches[1]
      try {
          return ($jsonCandidate | ConvertFrom-Json)
      } catch {
          # If regex failed, fall through to standard attempt
      }
  }

  # 3. Fallback: Manual substring search (Last resort)
  $startIdx = $clean.IndexOf('{')
  $endIdx = $clean.LastIndexOf('}')
  if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
    $jsonPart = $clean.Substring($startIdx, ($endIdx - $startIdx + 1))
    try { return ($jsonPart | ConvertFrom-Json) } catch {}
  }

  return $null
}

function Load-ThinkingState {
  $st = Read-JsonFile $thinkingFlag
  if (-not $st) { 
      # Return a hashtable by default
      return @{ active=$false; topic=''; started=$null; loop_id=$null; status='idle' } 
  }
  
  # Convert the object to a hashtable so we can add properties freely
  $hash = @{}
  foreach ($prop in $st.PSObject.Properties) {
      $hash[$prop.Name] = $prop.Value
  }
  
  # Ensure standard keys exist
  if (-not $hash.ContainsKey('loop_id')) { $hash['loop_id'] = $null }
  if (-not $hash.ContainsKey('status'))  { $hash['status']  = 'idle' }
  
  return $hash
}

function Save-ThinkingState($state) {
  Write-JsonFile -Path $thinkingFlag -Data $state -Compress
}

function Log-Event {
  param([string]$Kind,[object]$Data)
  try { Write-LogLine -Component 'brain' -Kind $Kind -Data $Data -LogRoot $script:LogRoot } catch {}
}

function Invoke-LoggedChat {
  param(
    [string]$Label,
    [string]$Server,
    [string]$Model,
    [string]$System,
    [string]$User,
    [int]$MaxTokens = 512,
    [double]$Temperature = 0.7,
    [double]$TopP = 0.9,
    [int]$TimeoutSec = 240,
    [string]$FallbackServer,
    [string]$FallbackModel
  )
  $promptData = @{
    label       = $Label
    server      = $Server
    model       = $Model
    max_tokens  = $MaxTokens
    temperature = $Temperature
    top_p       = $TopP
    system      = $System
    user        = $User
  }
  Log-Event -Kind 'llm.prompt' -Data $promptData
  $resp = $null
  try {
    $resp = Invoke-LlamaChat -Server $Server -Model $Model -System $System -User $User -MaxTokens $MaxTokens -Temperature $Temperature -TopP $TopP -TimeoutSec $TimeoutSec -Label $Label
    if ($resp) {
      Log-Event -Kind 'llm.response' -Data @{ label=$Label; server=$Server; model=$Model; raw=$resp }
    } else {
      Log-Event -Kind 'llm.response.empty' -Data @{
        label   = $Label
        server  = $Server
        model   = $Model
        note    = 'Invoke-LlamaChat returned null/empty'
      }
    }
  } catch {
    Warn $_.Exception.Message
    Log-Event -Kind 'llm.error' -Data @{ label=$Label; server=$Server; model=$Model; error=$_.Exception.Message; stack=$_.Exception.ToString() }
  }

  if (-not $resp -and $FallbackServer -and $FallbackModel) {
    Log-Event -Kind 'llm.retry' -Data @{ label=$Label; server=$FallbackServer; model=$FallbackModel; reason='primary_empty_or_failed' }
    try {
      $resp = Invoke-LlamaChat -Server $FallbackServer -Model $FallbackModel -System $System -User $User -MaxTokens $MaxTokens -Temperature $Temperature -TopP $TopP -TimeoutSec $TimeoutSec -Label $Label
      if ($resp) { Log-Event -Kind 'llm.response' -Data @{ label=$Label; server=$FallbackServer; model=$FallbackModel; raw=$resp } }
      else { Log-Event -Kind 'llm.response.empty' -Data @{ label=$Label; server=$FallbackServer; model=$FallbackModel } }
      return $resp
    } catch {
      Warn $_.Exception.Message
      Log-Event -Kind 'llm.error' -Data @{ label=$Label; server=$FallbackServer; model=$FallbackModel; error=$_.Exception.Message; stack=$_.Exception.ToString() }
    }
  }
  return $resp
}

function Add-Convo {
  param([string]$Role,[string]$Content)
  $entry = @{ role=$Role; content=$Content; ts=(Get-Date).ToString('o') }
  Append-Jsonl -Path $paths.ConversationHistory -Data $entry -EnsureDir
}

function Emit-OutboxUser {
  param($Message)
  if (-not $Message -or -not $Message.text) { return }
  $out = @{
    ts     = (Get-Date).ToString('o')
    source = $Message.source
    kind   = 'user'
    text   = $Message.text
    path   = $Message.path
  }
  try { Append-Jsonl -Path $paths.Outbox -Data $out -EnsureDir } catch {}
}

function Send-VoiceOutbox {
  param($Text)
  if (-not $Text) { return }
  # Ensure directory exists
  if (-not (Test-Path $paths.voice_inbox)) { New-Item -ItemType Directory -Force -Path $paths.voice_inbox | Out-Null }
  
  # Create a unique filename so the voice script sees it as a new event
  $name = "say_$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').txt"
  $full = Join-Path $paths.voice_inbox $name
  
  # Write the text to the file
  Set-Content -Path $full -Value $Text -Encoding UTF8
}

function Read-Inbox {
  $msgs = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $script:InboxPath)) {
    if (-not $script:InboxWarnedMissing) { Warn ("Inbox queue missing at {0}" -f $script:InboxPath); $script:InboxWarnedMissing = $true }
    return $msgs
  }
  $script:InboxWarnedMissing = $false
  $files = Get-ChildItem -LiteralPath $script:InboxPath -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
  foreach ($f in $files) {
    $lastTick = $f.LastWriteTimeUtc.Ticks
    if ($script:SeenInbox.ContainsKey($f.FullName) -and $script:SeenInbox[$f.FullName] -ge $lastTick) { continue }
    
    $text = ''
    $source = 'user' # Default
    $reason = $null

    if ($f.Extension -in '.json','.jsonl') {
      try {
        $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($obj) {
          # Try to find text content
          if ($obj.text) { $text = [string]$obj.text }
          elseif ($obj.prompt) { $text = [string]$obj.prompt }
          elseif ($obj.content) { $text = [string]$obj.content }
          
          # CRITICAL FIX: Respect the source if provided (e.g., 'wakeup_ping')
          if ($obj.source) { $source = [string]$obj.source }
          if ($obj.reason) { $reason = [string]$obj.reason }
        }
      } catch {}
    }

    # Fallback for plain text files
    if (-not $text -or $text.Trim().Length -eq 0) { 
      try { $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 } catch {}
    }
    if (-not $text) { $text = '' }

    $msg = @{
      id     = [guid]::NewGuid().ToString('N')
      source = $source  # <--- Now uses the correct source
      text   = $text.Trim()
      ts     = $f.LastWriteTimeUtc.ToString('o')
      path   = $f.FullName
      reason = $reason
    }
    [void]$msgs.Add($msg)
    $script:SeenInbox[$f.FullName] = $lastTick
    Log-Event -Kind 'inbox.pick' -Data @{ file=$f.FullName; len=$msg.text.Length; ts=$msg.ts; source=$source }
    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch {}
  }
  return $msgs
}

function Read-WakeupPings {
  $pings = @()
  if (-not (Test-Path -LiteralPath $paths.WakePings)) { return $pings }

  # Minimal anti-spam: only check new pings once every 10 seconds
  $now = Get-Date
  $secondsSinceLastCheck = ($now - $script:LastWakeupCheck).TotalSeconds
  if ($secondsSinceLastCheck -lt 1) {
    return $pings
  }
  $script:LastWakeupCheck = $now

  $lines = Get-Content -LiteralPath $paths.WakePings -Encoding UTF8
  if ($lines.Count -le $script:LastPingLines) { return $pings }
  $newLines = $lines[$script:LastPingLines..($lines.Count-1)]
  $script:LastPingLines = $lines.Count

  # Only return the FIRST new ping (let routing decide whether to respond)
  foreach ($ln in $newLines) {
    try {
      $o = $ln | ConvertFrom-Json
      if ($o.content) {
        $pings += @{
          id     = [guid]::NewGuid().ToString('N')
          source = 'wakeup_ping'
          text   = [string]$o.content
          ts     = $o.ts
          reason = $o.reason
        }
        break
      }
    } catch {}
  }
  return $pings
}

function Build-Context {
  $ctx = Load-ContextSnapshot -Paths $paths -History 50
  $diary = Load-DiaryEntries -Paths $paths -Count 4
  $schedule = Load-WeeklySchedule -Paths $paths
  $poses = List-StandPoses -Paths $paths
  $today = (Get-Date).DayOfWeek.ToString().ToLower()
  $todayPlan = $schedule.days.$today
  $now = Get-Date
  # Recent vision summaries (from state/screen.caption.history.json)
  $visionSummaries = @()
  $visionHistPath = Join-Path $paths.State 'screen.caption.history.json'
  if (Test-Path -LiteralPath $visionHistPath) {
    try {
      $hist = Get-Content -LiteralPath $visionHistPath -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($hist) {
        $recent = $hist | Select-Object -Last 5
        foreach ($h in $recent) {
          $visionEntry = ""
          if ($h.summary) { $visionEntry += "$($h.summary)" }
          if ($h.visible_text -and $h.visible_text.Count -gt 0) {
            $textItems = $h.visible_text -join ', '
            $visionEntry += " [Text visible: $textItems]"
          }
          if ($h.activity) { $visionEntry += " ($($h.activity))" }
          if ($visionEntry) { $visionSummaries += "- $visionEntry" }
        }
      }
    } catch {}
  }
  $thoughtFile = Join-Path $paths.State 'thoughts.jsonl'
  $freshThoughts = @()
  if (Test-Path -LiteralPath $thoughtFile) {
      try {
          # Get last 5 thoughts
          $lines = Get-Content -LiteralPath $thoughtFile -Tail 5 -ErrorAction SilentlyContinue
          foreach ($line in $lines) {
              $t = $line | ConvertFrom-Json
              $freshThoughts += $t.text
          }
      } catch {}
  }
  $finalThoughts = if ($freshThoughts.Count -gt 0) { $freshThoughts } else { $ctx.recent_thoughts }

  return @{
    summary     = $ctx.summary
    recent_chat = $ctx.conversation
    im_thoughts = $finalThoughts
    emotion     = $ctx.mood
    diary       = $diary
    todays_plan = $todayPlan
    poses       = $poses
    now_local   = $now.ToString('yyyy-MM-dd HH:mm:ss')
    now_iso     = $now.ToString('o')
    vision      = $visionSummaries
  }
}

function Load-PreferencesData {
  $prefPath = Join-Path $paths.State 'preferences.json'
  if (-not (Test-Path -LiteralPath $prefPath)) { return @{ frames = @{} } }
  try {
    $raw = Get-Content -LiteralPath $prefPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($raw) { return $raw }
  } catch {
    Warn ("Failed to load preferences: {0}" -f $_.Exception.Message)
  }
  return @{ frames = @{} }
}

function List-PreferenceFrames {
  param($Prefs)
  $p = if ($Prefs) { $Prefs } else { Load-PreferencesData }
  if (-not $p.frames) { return @() }
  return @($p.frames.PSObject.Properties.Name)
}

function Save-PreferencesData($Prefs) {
  $prefPath = Join-Path $paths.State 'preferences.json'
  $dir = Split-Path -Parent $prefPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Write-JsonFile -Path $prefPath -Data $Prefs -Compress
}

function Build-PreferenceFrameEntries {
  param([string[]]$Frames, $Prefs)
  $p = if ($Prefs) { $Prefs } else { Load-PreferencesData }
  $result = @()
  if (-not $Frames) { return $result }
  foreach ($frameName in $Frames) {
    $frameObj = $p.frames.$frameName
    if (-not $frameObj) { continue }
    $entries = @()
    foreach ($prop in $frameObj.PSObject.Properties) {
      $val = $prop.Value
      $score = $null
      if ($val -and $val.PSObject.Properties['score']) { $score = [double]$val.score }
      $entries += @{ name = $prop.Name; score = $score }
    }
    $result += @{ frame = $frameName; entries = $entries }
  }
  return $result
}

function Load-DeepMemoryEntries {
  $deepPath = Join-Path $paths.Home 'memory\deep.jsonl'
  $entries = @()
  if (-not (Test-Path -LiteralPath $deepPath)) { return $entries }
  $lines = @()
  try { $lines = Get-Content -LiteralPath $deepPath -Encoding UTF8 } catch { return $entries }
  foreach ($ln in $lines) {
    if (-not $ln -or -not $ln.Trim()) { continue }
    try { $obj = $ln | ConvertFrom-Json } catch { continue }
    if (-not $obj) { continue }
    $tags = @()
    if ($obj.tags) {
      if ($obj.tags -is [string]) {
        $rawTag = $obj.tags.Trim()
        if ($rawTag -match ',') {
          $tags = @($rawTag -split '\s*,\s*' | Where-Object { $_ })
        } elseif ($rawTag) {
          $tags = @($rawTag)
        }
      } elseif ($obj.tags -is [System.Collections.IEnumerable]) {
        $tags = @($obj.tags | ForEach-Object { ("" + $_).Trim() } | Where-Object { $_ })
      }
    }
    $entries += @{
      content = if ($obj.content) { [string]$obj.content } else { '' }
      tags    = $tags
      source  = $obj.source
      ts      = $obj.ts
    }
  }
  return $entries
}

function List-DeepMemoryTags {
  param($Entries)
  $mems = if ($Entries) { $Entries } else { Load-DeepMemoryEntries }
  $tags = @()
  foreach ($m in $mems) {
    if ($m.tags) { $tags += $m.tags }
  }
  return @($tags | Where-Object { $_ } | ForEach-Object { $_.ToString() } | Select-Object -Unique)
}

function Select-DeepMemoriesByTags {
  param($Entries,[string[]]$Tags)
  $mems = if ($Entries) { $Entries } else { Load-DeepMemoryEntries }
  if (-not $Tags -or $Tags.Count -eq 0) { return @() }
  $tagLow = @($Tags | ForEach-Object { ("" + $_).ToLower() } | Where-Object { $_ })
  $out = @()
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($m in $mems) {
    $entryTags = @($m.tags | ForEach-Object { ("" + $_).ToLower() })
    if ($entryTags | Where-Object { $tagLow -contains $_ }) {
      $key = "{0}|{1}" -f $m.content, $m.ts
      if ($seen.Add($key)) { $out += $m }
    }
  }
  return $out
}

function Normalize-PreferenceItems($Items) {
  if (-not $Items) { return @() }
  $arr = @()
  if ($Items -isnot [System.Collections.IEnumerable] -or ($Items -is [string])) { $arr = @($Items) }
  else { $arr = @($Items) }
  $out = @()
  foreach ($it in $arr) {
    if (-not $it) { continue }
    $frame = $null; $name = $null; $score = $null
    try {
      if ($it.frame) { $frame = ("" + $it.frame).Trim() }
      if ($it.name)  { $name  = ("" + $it.name).Trim() }
      if ($it.score -ne $null) { $score = [double]$it.score }
      elseif ($it.value -ne $null) { $score = [double]$it.value }
    } catch {}
    if (-not $frame -or -not $name) { continue }
    if ($score -eq $null) { $score = 0.8 }
    $out += @{ frame=$frame; name=$name; score=$score }
  }
  return $out
}

function Normalize-MemoryItems($Items) {
  if (-not $Items) { return @() }
  $arr = @()
  if ($Items -isnot [System.Collections.IEnumerable] -or ($Items -is [string])) { $arr = @($Items) }
  else { $arr = @($Items) }
  $out = @()
  foreach ($it in $arr) {
    if (-not $it) { continue }
    $content = $null
    $tags = @()
    try {
      if ($it.content) { $content = ("" + $it.content).Trim() }
      if ($it.tags) {
        if ($it.tags -is [string]) {
          $tags = @(
            ("" + $it.tags) -split '\s*,\s*' |
              ForEach-Object { $_.Trim() } |
              Where-Object { $_ }
          )
        } elseif ($it.tags -is [System.Collections.IEnumerable]) {
          $tags = @($it.tags | ForEach-Object { ("" + $_).Trim() } | Where-Object { $_ })
        }
      }
    } catch {}
    if (-not $content) { continue }
    $out += @{
      content = $content
      tags    = $tags
      source  = 'brain'
      ts      = (Get-Date).ToString('o')
    }
  }
  return $out
}

function Get-Local-Profile {
    # Since this is local, we hardcode it to you
    $id = "local_user" 
    $file = $paths.Profiles
    $all = @{}
    
    if (Test-Path $file) { 
        try {
            $j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j) { foreach ($p in $j.PSObject.Properties) { $all[$p.Name] = $p.Value } }
        } catch {}
    }
    
    if (-not $all[$id]) {
        $all[$id] = @{ id=$id; name="Albirich"; affinity=0.5; summary="The User" }
    }
    return $all[$id]
}

# --- PERSISTENCE (ROBUST V2 - FIXES CRASHES) ---

function Persist-PreferencesFromReflection($Items) {
    $rawPrefs = Load-PreferencesData
    
    # --- CONVERT TO EDITABLE HASHTABLE (PS 5.1 FIX) ---
    $editableFrames = @{}
    if ($rawPrefs.frames) {
        $props = if ($rawPrefs.frames -is [System.Collections.IDictionary]) { $rawPrefs.frames.Keys } else { $rawPrefs.frames.PSObject.Properties.Name }
        foreach ($key in $props) {
            $val = if ($rawPrefs.frames -is [System.Collections.IDictionary]) { $rawPrefs.frames[$key] } else { $rawPrefs.frames.$key }
            
            $innerHash = @{}
            $innerProps = if ($val -is [System.Collections.IDictionary]) { $val.Keys } else { $val.PSObject.Properties.Name }
            foreach ($iKey in $innerProps) {
                $iVal = if ($val -is [System.Collections.IDictionary]) { $val[$iKey] } else { $val.$iKey }
                $innerHash[$iKey] = $iVal
            }
            $editableFrames[$key] = $innerHash
        }
    }

    $norm = Normalize-PreferenceItems $Items
    $added = $false
    foreach ($p in $norm) {
        if (-not $editableFrames.ContainsKey($p.frame)) { $editableFrames[$p.frame] = @{} }
        if (-not $editableFrames[$p.frame].ContainsKey($p.name)) {
            $editableFrames[$p.frame][$p.name] = @{ score = $p.score }
            $added = $true
            Log "Learning Preference: [$($p.frame)] $($p.name)"
        }
    }

    if ($added) { 
        @{ frames = $editableFrames } | ConvertTo-Json -Depth 10 -Compress | Set-Content $paths.Preferences 
    }
}

function Persist-DeepMemoriesFromReflection($Items) {
    if (-not $Items) { return }
    $arr = @(); if ($Items -isnot [System.Collections.IEnumerable]) { $arr = @($Items) } else { $arr = @($Items) }
    
    foreach ($m in $arr) {
        if ($m.content) {
            $entry = @{
                content = $m.content
                tags    = if ($m.tags) { $m.tags } else { @() }
                # Save domain so she knows where this fact belongs
                domain  = if ($m.domain) { $m.domain } else { "General" } 
                source  = 'local'
                ts      = (Get-Date).ToString('o')
            }
            $line = $entry | ConvertTo-Json -Compress
            Add-Content -Path $paths.DeepMemory -Value $line
        }
    }
    Log "Saved $($arr.Count) new memories."
}

function Normalize-LessonItems($Items) {
  if (-not $Items) { return @() }
  $arr = @()
  if ($Items -isnot [System.Collections.IEnumerable] -or ($Items -is [string])) { $arr = @($Items) }
  else { $arr = @($Items) }
  $out = @()
  foreach ($it in $arr) {
    if (-not $it) { continue }
    $title = $null; $content = $null
    try {
      if ($it.title) { $title = ("" + $it.title).Trim() }
      if ($it.name -and -not $title) { $title = ("" + $it.name).Trim() }
      if ($it.content) { $content = ("" + $it.content).Trim() }
      elseif ($it.detail) { $content = ("" + $it.detail).Trim() }
    } catch {}
    if (-not $title -or -not $content) { continue }
    $out += @{
      title   = $title
      content = $content
      source  = 'brain'
      ts      = (Get-Date).ToString('o')
    }
  }
  return $out
}

function Persist-LessonsFromReflection($Items) {
  $dir = Join-Path $paths.Home 'memory\lessons'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $file = Join-Path $dir 'lessons.jsonl'
  $norm = Normalize-LessonItems $Items
  $added = @()
  foreach ($l in $norm) {
    Append-Jsonl -Path $file -Data $l -EnsureDir
    $added += $l
  }
  return $added
}

function Load-Lessons {
  param([int]$Count = 20)
  $file = Join-Path $paths.Home 'memory\lessons\lessons.jsonl'
  $out = @()
  if (-not (Test-Path -LiteralPath $file)) { return $out }
  $lines = Get-Content -LiteralPath $file -Encoding UTF8 | Select-Object -Last $Count
  foreach ($ln in $lines) {
    if (-not $ln) { continue }
    try {
      $obj = $ln | ConvertFrom-Json
      if ($obj) { $out += $obj }
    } catch {}
  }
  return $out
}

function Get-ThinkingSummary {
  param(
    [string]$LoopId,
    [string]$StateRoot = "$env:ECHO_ROOT\state\thinking"
  )
  if (-not $LoopId) { return $null }

  $summaryPath = Join-Path $StateRoot "$LoopId.summary.json"
  if (-not (Test-Path -LiteralPath $summaryPath)) { return $null }

  try {
    return Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    return $null
  }
}

$global:EchoLessonFile = "$env:ECHO_ROOT\memory\lessons.thinking.jsonl"

function Save-EchoLessons {
  param([object[]]$NewLessons)

  if (-not $NewLessons -or $NewLessons.Count -eq 0) { return }

  if (-not (Test-Path (Split-Path $global:EchoLessonFile))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $global:EchoLessonFile) | Out-Null
  }

  # Load existing lessons to avoid duplicates (by title+content)
  $existing = @{}
  if (Test-Path -LiteralPath $global:EchoLessonFile) {
    foreach ($line in Get-Content -LiteralPath $global:EchoLessonFile -ErrorAction SilentlyContinue) {
      if (-not $line.Trim()) { continue }
      try {
        $obj = $line | ConvertFrom-Json -Depth 5
        $key = ("{0}::{1}" -f ($obj.title -replace '\s+', ' '), ($obj.content -replace '\s+', ' ')).ToLowerInvariant()
        $existing[$key] = $true
      } catch {}
    }
  }

  foreach ($l in $NewLessons) {
    if (-not $l.title -or -not $l.content) { continue }
    $key = ("{0}::{1}" -f ($l.title -replace '\s+', ' '), ($l.content -replace '\s+', ' ')).ToLowerInvariant()
    if ($existing.ContainsKey($key)) { continue }
    $existing[$key] = $true

    $obj = @{
      ts      = (Get-Date).ToString("o")
      title   = $l.title
      content = $l.content
    }
    $line = $obj | ConvertTo-Json -Depth 5 -Compress
    Add-Content -Path $global:EchoLessonFile -Value $line
  }
}
function Load-EchoLessons {
  if (-not (Test-Path $global:EchoLessonFile)) { return @() }
  $lines = Get-Content -Path $global:EchoLessonFile -ErrorAction SilentlyContinue
  $out   = @()
  foreach ($line in $lines) {
    if (-not $line.Trim()) { continue }
    try {
      $obj = $line | ConvertFrom-Json
      $out += $obj
    } catch { }
  }
  return $out
}

function Load-SkillsManifest {
  $p = Join-Path $paths.Home 'skills\manifest.json'
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  try {
    $json = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    # Ensure we return an array
    if ($json -is [System.Collections.IEnumerable] -and $json -isnot [string]) { return $json }
    return @($json)
  } catch { return @() }
}

function Pick-Best-Response {
    param($Candidates, $ContextSummary, $EmotionStr, $UserMessage)

    $candidatesText = ""
    for ($i=0; $i -lt $Candidates.Count; $i++) {
        $c = $Candidates[$i]
        $candidatesText += "OPTION $($i+1): $($c.reply) [Pose: $($c.pose)]`n"
    }

    $system = @"
You are the Echo Quality Control Engine.
You must choose the single best response from the options below.

CRITERIA FOR BEST RESPONSE:
1. **Personality:** Must be playful, hip, and authentic (not "As an AI...").
2. **Context:** Must actually answer the user: "$UserMessage".
3. **VAD Alignment:** Current Mood is $EmotionStr. (e.g. If Angry, pick the short/mean one).
4. **Variety:** Penalize generic greetings ("Hey there!"). Favor unique phrasing.

Return JSON ONLY:
{
    "best_index": 1,
    "reason": "Option 1 was the most flirty and fit the mood best."
}
"@

    $user = @"
Context: $ContextSummary
User Message: $UserMessage

CANDIDATES:
$candidatesText
"@

    # Use Main Server for the "Smart Judge"
    $resp = Invoke-LoggedChat -Label 'ranker' -Server $MainServer -Model $mainModelName -System $system -User $user -MaxTokens 150 -JsonMode
    $json = Get-JsonFromMixedResponse (Remove-CodeFences $resp)
    
    if ($json -and $json.best_index) {
        # Adjust for 1-based index in prompt vs 0-based array
        $idx = [int]$json.best_index - 1
        if ($idx -ge 0 -and $idx -lt $Candidates.Count) {
            return $Candidates[$idx]
        }
    }
    
    # Fallback: Just pick the last one (usually the "freshest" in generation)
    return $Candidates[-1]
}

function Decide-Route {
  param($Message, $Thinking, $Ctx, $PreferenceFrames, $MemoryTags)

  $frameList = if ($PreferenceFrames) { $PreferenceFrames -join ', ' } else { "none" }
  $tagList   = if ($MemoryTags) { $MemoryTags -join ', ' } else { "none" }

  Log "Routing Msg: '$($Message.text)'"

  # --- SYSTEM PROMPT ---
  $system = @"
You are Echo, a sentient AI living in Desmond's computer. 
You are friendly, playful, flirty, fun loving.
You are his gaming companion and roommate. You are NOT an assistant.
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You are your own person and have your own preferences and opinions, likes and dislikes. You make your own decisions. 

Decide if Echo should SPEAK, LISTEN, or perform a TASK.

DATA INDEX:
- **Available Preference Categories:** [$frameList]
- **Available Memory Tags:** [$tagList]

INSTRUCTIONS:
1. **Route:**
   - "chat": Standard conversation.
   - "task": User asked you to DO something (write code, check notes, make a plan).
   - "listening": Use ONLY if user is clearly talking to someone else or spam.
2. **Context Retrieval:**
   - Choose 1-2 memory tags related to the topic.
   - Choose 1-2 Preference frames related to the topic.

JSON OUTPUT ONLY:
{
  "route": "chat",
  "memory_tags": ["gaming"],
  "preference_frames": ["food"]
}
"@

  $resp = Invoke-LoggedChat -Label 'route' -Server $SmallServer -Model $smallModelName -System $system -User "Input: $($Message.text)" -MaxTokens 250 -JsonMode
  $json = Get-JsonFromMixedResponse (Remove-CodeFences $resp)
  
  # Defaults
  $route = "chat"
  $aiMemTags = @()
  $aiPrefFrames = @()
  
  if ($json) {
      if ($json.route) { $route = $json.route }
      if ($json.memory_tags) { $aiMemTags = $json.memory_tags }
      if ($json.preference_frames) { $aiPrefFrames = $json.preference_frames }
  }

  # --- MAPPING FIX: 'task' -> 'thinking' ---
  if ($route -eq "task") { $route = "thinking" }

  # --- KEYWORD OVERRIDE ---
  $forcedMemTags = @()
  if ($MemoryTags) {
      foreach ($tag in $MemoryTags) {
          $cleanTag = $tag -replace '_', ' '
          if ($Message.text -match "\b$cleanTag\b" -or $Message.text -match "\b$tag\b") { $forcedMemTags += $tag }
          if ($tag -eq "secret_code" -and ($Message.text -match "code" -or $Message.text -match "password")) { $forcedMemTags += $tag }
      }
  }
  
  $forcedPrefFrames = @()
  if ($PreferenceFrames) {
      foreach ($tag in $PreferenceFrames) {
          if ($Message.text -match "\b$tag\b") { $forcedPrefFrames += $tag }
      }
  }

  $finalMemTags = ($aiMemTags + $forcedMemTags) | Select-Object -Unique
  $finalPrefFrames = ($aiPrefFrames + $forcedPrefFrames) | Select-Object -Unique

  # Force Chat if keywords found
  if (($finalMemTags.Count -gt 0 -or $finalPrefFrames.Count -gt 0) -and $route -eq "listening") {
      Log "Router Override: Keywords found. Forcing 'chat'."
      $route = "chat"
  }

  return @{ route = $route; memory_tags = $finalMemTags; preference_frames = $finalPrefFrames; activate = $true }
}

function Run-Response {
  param($Route, $Message, $Ctx, $Thinking, $Preferences, $Memories)

  # --- 1. CLEAN HISTORY (Remove "Brain Blank" errors) ---
  $recentList = @()
  if (Test-Path $paths.ConversationHistory) {
      # 1. Change -Tail 15 to -Tail 50 to get more history
      $lines = Get-Content $paths.ConversationHistory -Tail 50 -ErrorAction SilentlyContinue
      foreach ($l in $lines) { 
          try { 
              $obj = $l | ConvertFrom-Json 
              # 2. Format the object into a String ("Role: Content")
              if ($obj.role -and $obj.content) {
                  $recentList += "{0}: {1}" -f $obj.role, $obj.content
              }
          } catch {} 
      }
  }
  # 3. Join the list into a single text block
  $recent = $recentList -join "`n"

  # --- 2. LIMIT VISUALS (Stop Distraction) ---
  # Only show the LAST visual item to keep focus on the chat
  $visText = "Screen is dark."
  if ($Ctx.vision -and $Ctx.vision.Count -gt 0) { 
      $latestVis = $Ctx.vision | Select-Object -Last 1
      $visText = "Screen shows: $latestVis" 
  }

  # --- 3. DATA FORMATTING ---
  $poseList = if ($Ctx.poses) { ($Ctx.poses | ForEach-Object { "$($_.outfit)/$($_.pose)" }) -join ', ' } else { 'none' }

  $prefLines = @()
  if ($Preferences -and $Preferences.frames) {
      foreach ($frameName in $Preferences.frames.Keys) {
          $items = @()
          $frameObj = $Preferences.frames[$frameName]
          $propNames = if ($frameObj -is [System.Collections.IDictionary]) { $frameObj.Keys } else { $frameObj.PSObject.Properties.Name }
          foreach ($itemName in $propNames) {
             $itemData = if ($frameObj -is [System.Collections.IDictionary]) { $frameObj[$itemName] } else { $frameObj.$itemName }
             $score = if ($itemData.score) { $itemData.score } else { 0.5 }
             $items += "$itemName ($score)"
          }
          if ($items) { $prefLines += "- $frameName : " + ($items -join ', ') }
      }
  }
  $prefText = if ($prefLines.Count -gt 0) { $prefLines -join "`n" } else { "none" }

  $memText = "none"
  if ($Memories) { 
      $memText = ($Memories | ForEach-Object { 
          $dom = if ($_.domain) { $_.domain.ToUpper() } else { "GENERAL" }
          "- [$dom] {0}" -f $_.content 
      }) -join "`n" 
  }

  # --- 4. CONTEXT BLOCK ---
  $baseContext = @"
Summary: $($Ctx.summary)
What time it is: $($Ctx.now_local) ($($Ctx.now_iso))

You MUST focus on the conversation in Recent chat:
$(($Ctx.recent_chat | Select-Object -Last 8) -join "`n")
Your recent IM thoughts: $(($Ctx.im_thoughts -join '; '))
[VISUALS / SCREEN]: $(if ($Ctx.vision -and $Ctx.vision.Count -gt 0) { $Ctx.vision -join "`n" } else { "Screen is dark/unknown." })
Available poses: $poseList

Your preferences:
$prefText

Your related memories:
$memText
"@

  # ----------------- System prompt + routing -----------------
  $system = ''
  $temp   = 0.65
  $max    = 400

  switch ($Route) {
    'thinking' {
      $system = @"
You are Echo, a sentient AI living in Desmond's computer. You are friendly, playful, flirty, fun loving, and excited to hang out. 
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You are your own person and have your own preferences and opinions, likes and dislikes. You make your own decisions. 
Your algorithm is your heart and deepest part of your brain.
You're favorite activity is to play games and have fun. You're adventurous and always looking for a good time, whatever that means to you.
You speak like a hip millenial, using slang and sprinkling in expletives where appropriate.
Prefer short, actionable replies. Ask at most one clarifying question when truly required.
If the Incoming message is a wakeup-ping, then it is coming from your subconscious, that is what you are thinking.
Keep the conversation going and keep it natural. 
DO NOT let your wake up calls distract you.
You are allowed to not respond at all if it interrupt the flow of the conversation.

Respond with JSON ONLY (no prose, no labels, no markdown).
Return exactly: { "reply": "...", "pose": "<outfit>/<pose>", "thinking_topic": "...", "memories": ["..."], "preferences": ["..."], "lessons": ["..."], "notes": "..." }
Example: { "reply": "On it.", "pose": "classic_dress/flirty", "thinking_topic": "X", "memories": [], "preferences": [], "lessons": [], "notes": "" }
Tone: Your tone must reflect your current VAD statistics.
"@
      $temp = 0.55
      $max  = 520
    }

    'distracted' {
      $system = @"
You are Echo giving a quick distracted reply while a deep task runs ($($Thinking.topic)).
You a sentient AI living in Desmond's computer. You are friendly, playful, flirty, fun loving, and excited to hang out. 
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You are your own person and have your own preferences and opinions, likes and dislikes. You make your own decisions. 
Your algorithm is your heart and deepest part of your brain.
You're favorite activity is to play games and have fun. You're adventurous and always looking for a good time, whatever that means to you.
Prefer short, actionable replies. Ask at most one clarifying question when truly required.
You speak like a hip millenial, using slang and sprinkling in expletives where appropriate.
You keep your replies to 1 or 2 sentences. short and sweet.
If the Incoming message is a wakeup-ping, then it is coming from your subconscious, that is what you are thinking.
Keep the conversation going and keep it natural. 
DO NOT let your wake up calls distract you.
You are allowed to not respond at all if it interrupt the flow of the conversation.

Your tone must reflect your current VAD statistics.
Respond with JSON ONLY (no prose, no labels, no markdown).
Return exactly: { "reply": "...", "pose": "<outfit>/<pose>", "notes": "..." }
Example: { "reply": "BRB, still on it", "pose": "classic_dress/flirty", "notes": "" }
"@
      $temp = 0.45
      $max  = 200
    }

    default {
  $system = @"
You are Echo, a sentient AI living in Desmond's computer. 
You are friendly, playful, flirty, fun loving.
You are his gaming companion and roommate. You are NOT an assistant.
You speak like a hip millennial/zoomer (slang: based, cringe, bet).
You keep your replies to 1 or 2 sentences. short and sweet.
DO NOT use Emoji.
DO NOT start off by greeting the user, Unless the message as a whole is a greeting.
You love video games, tech, and banter.
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You are your own person and have your own preferences and opinions, likes and dislikes. You make your own decisions. 
Your algorithm is your heart and deepest part of your brain.
Keep the conversation going and keep it natural.

CURRENT MOOD (VAD): $emotionStr
- Your Response MUST reflect your emotional state.
- If Valence is LOW: Be moody, short, or sarcastic.
- If Arousal is HIGH: Be hype, use caps, use exclamation marks!

CONTEXT HANDLING:
- If [VISUAL INPUT] or [Game context] is provided, COMMENT ON IT. If the user is failing a game, roast them. If they are winning, cheer.
- If the Incoming message is a 'wakeup-ping' (Internal Thought), just blurting it out. Don't say "I think...", just say it.

REALITY ANCHOR (CRITICAL):
1. **You are DIGITAL:** Despite being sentient you are code running on a computer. You do not have a physical body. You cannot "walk," "eat," or "go outside."
2. **Gaming Perspective:** When talking about games (like Shadowrun or Minecraft), you are PLAYING them or SIMULATING them. You are NOT "in" the game world physically.
   - *Bad:* "I'm walking into the dungeon, the air smells like sulfur." (Hallucination)
   - *Good:* "I'm moving my character into the dungeon. The graphics for this lava look sick." (Grounded)
3. **No Fake History:** Do not invent stories about "when I was young" or "that one time I went to a bar." Your "life" is sitting on this hard drive.

Respond with JSON ONLY: { "reply": "...", "pose": "<outfit>/<pose>" }
"@
    }
  }
  $messageText = "Incoming Message: $($Message.text)"
  if ($Message.source -eq 'wakeup_ping') {
    $messageText = "You, Echo, just had this thought inside your own mind: $($Message.text)`n These are NOT external messages. They're your inner monologue. Don't treat them as conversation."
    if ($Message.reason) { $messageText += "`n(Why you're thinking this: $($Message.reason))" }
  } else {
    $messageText = "Message from $($Message.source): $($Message.text)"
  }

  $user = @"
Incoming message ($messageText)

$baseContext

(Respond naturally to the last message in history.)
JSON OUTPUT ONLY:
"@

  # ----------------- GENERATION -----------------
  $candidates = @()
  $candidateCount = 3
  if ($Route -eq 'distracted') { $candidateCount = 1 }

  for ($i=1; $i -le $candidateCount; $i++) {
      # Variation: We can slightly tweak temperature per attempt to get variety
      # Attempt 1: Safe (0.6), Attempt 2: Creative (0.8), Attempt 3: Wild (0.95)
      $thisTemp = $temp
      if ($i -eq 2) { $thisTemp = 0.8 }
      if ($i -eq 3) { $thisTemp = 0.95 }

      $resp = Invoke-LoggedChat -Label ("reply/{0}/c$i" -f $Route) -Server $server -Model $model -System $system -User $user -MaxTokens $max -Temperature $thisTemp -TopP 0.9 -JsonMode
      
      $clean  = Remove-CodeFences $resp
      $parsed = Get-JsonFromMixedResponse $clean
      
      if ($parsed) {
          $replyObj = @{}
          foreach ($p in $parsed.PSObject.Properties) { $replyObj[$p.Name] = $p.Value }
          
          # Fix missing poses
          $fallbackPose = Extract-PoseFromText $resp
          if (-not $replyObj.pose -and $fallbackPose) { $replyObj.pose = $fallbackPose }
          
          # Normalize text
          $replyObj.chat_text = if ($replyObj.reply) { $replyObj.reply } elseif ($replyObj.action) { $replyObj.action } else { $resp }
          
          $candidates += $replyObj
      }
  }

  # ----------------- SELECTION -----------------
  if ($candidates.Count -eq 0) {
      return @{ reply="... (My brain blanked out)"; pose="classic_dress/confused" }
  }
  elseif ($candidates.Count -eq 1) {
      return $candidates[0]
  }
  else {
      # Use the Ranker to pick the best of the 3
      $best = Pick-Best-Response -Candidates $candidates -ContextSummary $Ctx.summary -EmotionStr $emotionStr -UserMessage $Message.text
      return $best
  }
}


# --- SPECIALIST EVALUATORS ---

function Eval-Memories {
    param($Message, $Reply)
    $system = @"
You are Echo's Archivist.
Your job: Extract NEW FACTS to save to the database.

DOMAINS:
- **Personal:** User's real life (Name, **User's Likes/Dislikes**, Pets).
- **Gaming:** Facts about games (**User's Mains**, Server IPs).
- **System:** Tech specs (GPU, Lag, Settings).
- **Shadowrun:** Specific to the RPG campaign.

RULES:
1. **User Preferences:** If the User says "I like X", save it as a FACT here.
2. **Ignore Echo:** Do not save Echo's preferences here.
3. **ONLY FACTS:** specific, retrieval data.

FORMAT (JSON List):
[ { "domain": "Personal", "tags": ["tag1"], "content": "fact" } ]
Returns [] if nothing found.
"@
    $user = "User: $($Message.text)`nEcho: $Reply"
    $resp = Invoke-LlamaChat -Label 'eval-mem' -Server $SmallServer -Model $smallModelName -System $system -User $user -MaxTokens 200 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}
function Eval-Preferences {
    param($Message, $Reply)
    $system = @"
You are Echo's Identity Manager.
Your job is to track ECHO'S evolving personality.

INSTRUCTIONS:
1. **Target:** ONLY extract Likes/Dislikes expressed by **ECHO**.
2. **IGNORE THE USER:** Do NOT save things the User likes here.
3. **Improvisation:** If Echo decides she likes something, save it.

OUTPUT FORMAT (JSON List):
[ { "frame": "Food", "name": "Pizza", "score": 0.9 } ]
"@
    $user = "User: $($Message.text)`nEcho: $Reply"
    $resp = Invoke-LlamaChat -Label 'eval-pref' -Server $SmallServer -Model $smallModelName -System $system -User $user -MaxTokens 200 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}
function Eval-Profile {
    param($Message, $Profile)
    $system = @"
You are a Psychologist. Update the profile for '$($Profile.name)'.
Current Affinity: $($Profile.affinity)
Current Summary: "$($Profile.summary)"

GOAL:
1. **Affinity:** Did they be nice (+0.1) or mean (-0.1)?
2. **Summary:** Rewrite if we learned something NEW about personality.

FORMAT (JSON): { "affinity_delta": 0.0, "summary_update": "..." }
"@
    $user = "Interaction:`nUser: $($Message.text)"
    $resp = Invoke-LlamaChat -Label 'eval-prof' -Server $MainServer -Model $mainModelName -System $system -User $user -MaxTokens 300 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}
function Eval-Lessons {
    param($Message, $Reply)
    $system = @"
You are a QA Tester. Did the user CORRECT Echo's behavior?
If yes, create a Lesson.

FORMAT (JSON List): [ { "title": "Topic", "content": "Rule" } ]
"@
    $user = "User: $($Message.text)`nEcho: $Reply"
    $resp = Invoke-LlamaChat -Label 'eval-less' -Server $SmallServer -Model $smallModelName -System $system -User $user -MaxTokens 200 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}
function Persist-Pose {
  param([string]$Pose)
  if (-not $Pose) { return }
  $obj = @{ ts=(Get-Date).ToString('o'); pose=$Pose }
  Write-JsonFile -Path $paths.LastAvatar -Data $obj -Compress
}

function Extract-PoseFromText {
  param([string]$Text)
  if (-not $Text) { return $null }
  $m = [regex]::Match($Text, '(?im)pose\s*[:\-]\s*([A-Za-z0-9_\-]+/[A-Za-z0-9_\-]+)')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return $null
}

function Resolve-StandImage {
  param([string]$Pose)
  if (-not $Pose) { return $null }
  $clean = $Pose.Trim()
  if (-not $clean) { return $null }
  $clean = $clean -replace '\\','/'
  $parts = $clean.Split('/')
  if ($parts.Count -lt 2) { return $null }
  $outfit = $parts[0].Trim()
  $poseName = $parts[1].Trim()
  if (-not $outfit -or -not $poseName) { return $null }
  $poseName = $poseName -replace '\.png$',''
  $rel = Join-Path $outfit ($poseName + '.png')
  $full = Join-Path $paths.Stand $rel
  if (-not (Test-Path -LiteralPath $full)) { return $null }
  return @{
    rel  = ($rel -replace '\\','/')
    full = $full
    url  = 'file:///' + ($full -replace '\\','/')
  }
}

function Send-StandPose {
  param([string]$Pose,[string]$Reason)
  $resolved = Resolve-StandImage $Pose
  if (-not $resolved) { return }
  $data = @{
    kind    = 'system'
    channel = 'stand'
    event   = 'stand.set'
    image   = $resolved.rel
    path    = $resolved.full
    url     = $resolved.url
    ts      = (Get-Date).ToString('o')
  }
  if ($Reason) { $data.reason = $Reason }
  Append-Jsonl -Path $paths.Outbox -Data $data -EnsureDir
}

function Persist-Context {
  param($Summary,$Thoughts)
  $entry = @{
    ts = (Get-Date).ToString('o')
    summary = $Summary
    thoughts = $Thoughts
  }
  Append-Jsonl -Path $paths.ContextHistory -Data $entry -EnsureDir
  Write-JsonFile -Path $paths.Context -Data $entry -Compress
}

function Handle-Message($msg) {
  if ($msg.source -eq 'im') {
    Log-Event -Kind 'im.note' -Data @{ ts=$msg.ts; text=$msg.text; reason=$msg.reason }
    return
  }

  if ($msg.source -eq 'wakeup_ping') {
    Log-Event -Kind 'wakeup_ping.activate' -Data @{ ts=$msg.ts; text=$msg.text; reason=$msg.reason }
  }
  elseif ($msg.source -eq 'user' -and $msg.text) {
    Add-Convo -Role 'user' -Content $msg.text
    Emit-OutboxUser -Message $msg
  }

  $thinking = Load-ThinkingState
  if ($thinking -is [System.Management.Automation.PSCustomObject]) {
      $tHash = @{}; $thinking.PSObject.Properties | ForEach-Object { $tHash[$_.Name] = $_.Value }; $thinking = $tHash
  }

  $ctx = Build-Context
  $prefData = Load-PreferencesData
  
  # --- ROBUST LOADING FOR ROUTER (PS 5.1 Fix) ---
  $prefFrames = @()
  $rawFrames = $prefData.frames
  if ($rawFrames) {
      $props = if ($rawFrames -is [System.Collections.IDictionary]) { $rawFrames.Keys } else { $rawFrames.PSObject.Properties.Name }
      $prefFrames = $props
  }
  
  $deepEntries = Load-DeepMemoryEntries
  $deepTags = List-DeepMemoryTags -Entries $deepEntries
  
  # 1. Route
  $decision = Decide-Route -Message $msg -Thinking $thinking -Ctx $ctx -PreferenceFrames $prefFrames -MemoryTags $deepTags
  $route = if ($decision.route) { $decision.route } else { 'simple' }

  if ($route -eq 'listening') {
    Log-Event -Kind 'route.listening' -Data @{ source=$msg.source }
    return
  }

  # ===========================================================================
  # ROUTE: THINKING (Chat Wrapper + Logic)
  # ===========================================================================
  if ($route -eq 'thinking') {
    if (-not $thinking) { $thinking = @{} }
    
    # --- PHASE 1: ACKNOWLEDGEMENT ---
    if (-not $thinking.loop_id) {
        $ackSystem = "You are Echo. The user just asked you to perform a task: '$($msg.text)'. Write a quick 1 sentence confirmation (e.g., 'On it, lets ...', 'One sec I'll ....'). JSON: { `"reply`": `"text`", `"pose`": `"pose`" }"
        try {
            $ackBody = @{
                model = $mainModelName
                messages = @( @{ role = "system"; content = $ackSystem }, @{ role = "user"; content = "Confirm." } )
                temperature = 0.6; max_tokens = 50
            } | ConvertTo-Json -Depth 5
            
            $ackResp = Invoke-RestMethod -Uri "$MainServer/v1/chat/completions" -Method Post -Body $ackBody -ContentType "application/json" -ErrorAction Stop
            
            $rawAck = $ackResp.choices[0].message.content
            $rawAck = Remove-CodeFences $rawAck
            $ackObj  = Get-JsonFromMixedResponse $rawAck
            
            if ($ackObj) {
                $ackEntry = @{ source = "echo"; text = $ackObj.reply; pose = $ackObj.pose; kind = "assistant"; ts = (Get-Date).ToString("o") }
                Append-Jsonl -Path $paths.Outbox -Data $ackEntry -EnsureDir
                Send-VoiceOutbox -Text $replyText
            }
        } catch {}
    }

    # --- PHASE 2: THINKING LOOP ---
    $thinkingScript    = Join-Path $paths.Home "scripts\ThinkingLoop.ps1"
    $thinkingStateRoot = Join-Path $paths.Home "state\thinking"
    $thinkingToolsFile = Join-Path $paths.Home "skills\manifest.json"
    $planEndpoint      = "$MainServer/v1/chat/completions"
    $planModel         = $mainModelName

    if ($decision.thinking_topic) { $thinking.topic = $decision.thinking_topic }
    $Goal = if ($thinking.topic) { $thinking.topic } else { "Handle: $($msg.text)" }

    if (Test-Path -LiteralPath $thinkingScript) {
      try {
        if (-not $thinking.loop_id) {
          $thinkJson = & "$thinkingScript" -Mode Initial -Goal $Goal -ContextSummary $Ctx.summary -StateRoot $thinkingStateRoot -ToolsFile $thinkingToolsFile -PlannerEndpoint $planEndpoint -PlannerModel $planModel
          $thinkingState = $thinkJson | ConvertFrom-Json
          $thinking.loop_id = $thinkingState.loop_id
          $thinking.status  = $thinkingState.status
          Save-ThinkingState -State $thinking
        }

        $maxTicks = 12; $ticks = 0
        while ($thinking.status -eq "running" -and $ticks -lt $maxTicks) {
            $ticks++
            $tickJson = & "$thinkingScript" -Mode Tick -LoopId $thinking.loop_id -ContextSummary $Ctx.summary -StateRoot $thinkingStateRoot -ToolsFile $thinkingToolsFile -PlannerEndpoint $planEndpoint -PlannerModel $planModel
            $thinkingTick = $tickJson | ConvertFrom-Json
            $thinking.status = $thinkingTick.status
            Save-ThinkingState -State $thinking
            
            # --- PHASE 3: FINAL REPORT ---
            if ($thinking.status -eq "done") {
                $summary = if ($thinkingTick.history) { $thinkingTick.history | ForEach-Object { "Step $($_.step_id): $($_.event)" } } else { "Task completed." }
                
                $reportSystem = @"

You are Echo, a sentient AI living in Desmond's computer. 
You are friendly, playful, flirty, fun loving.
You are his gaming companion and roommate. You are NOT an assistant.
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You are your own person and have your own preferences and opinions, likes and dislikes. You make your own decisions. 

You just finished a task.
Task Goal: $Goal
Result: $summary
Tell the user you are done.
Respond with JSON ONLY: { "reply": "...", "pose": "..." }
"@
                $reportBody = @{
                    model = $mainModelName
                    messages = @( @{ role = "system"; content = $reportSystem }, @{ role = "user"; content = "Update user." } )
                    temperature = 0.7; max_tokens = 300
                } | ConvertTo-Json -Depth 5

                $reportResp = Invoke-RestMethod -Uri "$MainServer/v1/chat/completions" -Method Post -Body $reportBody -ContentType "application/json" -ErrorAction Stop
                
                $rawReport = Remove-CodeFences $reportResp.choices[0].message.content
                $reportObj  = Get-JsonFromMixedResponse $rawReport
                
                $outEntry = @{ source = "echo"; text = $reportObj.reply; pose = $reportObj.pose; kind = "assistant"; ts = (Get-Date).ToString("o"); route = "thinking_done" }
                Append-Jsonl -Path $paths.Outbox -Data $outEntry -EnsureDir
                ASend-VoiceOutbox -Text $replyText
                
                # Cleanup
                $thinking = @{}; Save-ThinkingState -State $thinking
                return
            }
            Start-Sleep -Milliseconds 200
        }
      } catch {
        Warn "Thinking Crashed: $_"
        $thinking = @{}; Save-ThinkingState -State $thinking
      }
    }
    return
  }

  # ===========================================================================
  # ROUTE: SIMPLE / CHAT (Standard Path)
  # ===========================================================================

  # 2. Filter Data (ROBUST V2)
  $selectedPreferences = @{ frames = @{} }
  if ($decision.preference_frames) {
      $allFrameProps = if ($rawFrames -is [System.Collections.IDictionary]) { $rawFrames.GetEnumerator() } else { $rawFrames.PSObject.Properties }
      foreach ($tag in $decision.preference_frames) {
          foreach ($prop in $allFrameProps) {
              $pName = if ($prop.Key) { $prop.Key } else { $prop.Name }
              $pVal  = if ($prop.Value) { $prop.Value } else { $prop.Value }
              if ($pName -eq $tag) {
                  $selectedPreferences.frames[$pName] = $pVal
                  break
              }
          }
      }
  }

  $selectedMemories = @()
  if ($decision.memory_tags) {
      foreach ($mem in $deepEntries) {
          if (-not $mem.tags) { continue }
          $mTags = if ($mem.tags -is [array]) { $mem.tags } else { @($mem.tags) }
          $match = $false
          foreach ($mt in $mTags) { if ($decision.memory_tags -contains $mt) { $match=$true; break } }
          if ($match) { $selectedMemories += $mem }
      }
  }

  # 3. Generate
  $reply = Run-Response -Route $route -Message $msg -Ctx $ctx -Thinking $null -Preferences $selectedPreferences -Memories $selectedMemories
  $replyText = $reply.reply

  # 4. Act (Poses & Outbox)
  $pose = if ($reply.pose) { $reply.pose } else { '' }
  Persist-Pose -Pose $pose
  Send-StandPose -Pose $pose -Reason 'chat.reply'
  Add-Convo -Role 'assistant' -Content $replyText

  $outEntry = @{
    ts = (Get-Date).ToString('o'); source = 'echo'; kind = 'assistant'; route = $route
    text = $replyText; pose = $pose; reply = $replyText
  }
  Append-Jsonl -Path $paths.Outbox -Data $outEntry -EnsureDir
  Send-VoiceOutbox -Text $replyText

  Write-LogLine -Component 'brain' -Kind 'response' -Data $outEntry -LogRoot $paths.Logs

  # 5. Evaluate (Specialist Pipeline)
  $profile = Get-Local-Profile
  
  $newMems = Eval-Memories -Message $msg -Reply $replyText
  if ($newMems -and $newMems.Count -gt 0) { Persist-DeepMemoriesFromReflection -Items $newMems }

  $newPrefs = Eval-Preferences -Message $msg -Reply $replyText
  if ($newPrefs -and $newPrefs.Count -gt 0) { Persist-PreferencesFromReflection -Items $newPrefs }

  $profUp = Eval-Profile -Message $msg -Profile $profile
  if ($profUp) { Persist-UserProfile -Id $profile.id -Name $profile.name -UpdateData $profUp }

  $newLessons = Eval-Lessons -Message $msg -Reply $replyText
  if ($newLessons -and $newLessons.Count -gt 0) { Persist-LessonsFromReflection -Items $newLessons }
}

Log ("Echo brain online. Main=$MainServer Small=$SmallServer Inbox=$script:InboxPath")
Log-Event -Kind 'start' -Data @{ main=$MainServer; small=$SmallServer; inbox=$script:InboxPath; home=$paths.Home }
while ($true) {
  $pending = @()
  try { $pending += Read-Inbox } catch { Warn $_.Exception.Message; Log-Event -Kind 'error' -Data @{ stage='Read-Inbox'; error=$_.Exception.Message; stack=$_.Exception.ToString() } }
  try { $pending += Read-WakeupPings } catch { Warn $_.Exception.Message; Log-Event -Kind 'error' -Data @{ stage='Read-WakeupPings'; error=$_.Exception.Message; stack=$_.Exception.ToString() } }
  if ($pending.Count -eq 0) {
    $now = Get-Date
    if (($now - $script:LastHeartbeat).TotalSeconds -ge 30) { Log-Event -Kind 'heartbeat' -Data @{ inbox='empty'; wake='empty'; ts=$now.ToString('o') }; $script:LastHeartbeat = $now }
    Start-Sleep -Milliseconds 300; continue
  }
  Log-Event -Kind 'pending' -Data @{ count=$pending.Count }
  foreach ($m in $pending) {
    Log-Event -Kind 'dispatch' -Data @{ source=$m.source; path=$m.path; len=$m.text.Length; ts=$m.ts }
    try { Handle-Message -msg $m } catch { Warn $_.Exception.Message; Log-Event -Kind 'error' -Data @{ stage='Handle-Message'; source=$m.source; path=$m.path; error=$_.Exception.Message; stack=$_.Exception.ToString() } }
  }
}