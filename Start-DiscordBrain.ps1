[CmdletBinding()]
param(
  [string]$MainServer = 'http://127.0.0.1:8080',
  [string]$SmallServer = 'http://127.0.0.1:8081'
)

$ErrorActionPreference = 'Stop'
Write-Host "--- DISCORD BRAIN STARTUP ---" -ForegroundColor Cyan

# --- 1. SETUP LOGGING (First priority) ---
try {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $ScriptRoot) { $ScriptRoot = Get-Location }
    
    $LogDir = Join-Path $ScriptRoot 'logs'
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $DebugLogFile = Join-Path $LogDir 'discord_brain.debug.log'
    
    function Log([string]$msg) {
        $ts = (Get-Date).ToString('HH:mm:ss')
        $line = "[$ts] [DiscordBrain] $msg"
        Write-Host $line -ForegroundColor Green
        try { Add-Content -Path $DebugLogFile -Value $line -Force -ErrorAction SilentlyContinue } catch {}
    }

    function Warn([string]$msg) {
        $ts = (Get-Date).ToString('HH:mm:ss')
        $line = "[$ts] [DiscordBrain][WARN] $msg"
        Write-Host $line -ForegroundColor Yellow
        try { Add-Content -Path $DebugLogFile -Value $line -Force -ErrorAction SilentlyContinue } catch {}
    }
    
    function Log-Block([string]$Header, [string]$Content) {
        $line = "`n[{0}] === {1} ===`n{2}`n=====================`n" -f (Get-Date).ToString('HH:mm:ss'), $Header, $Content
        try { Add-Content -Path $DebugLogFile -Value $line -Force -ErrorAction SilentlyContinue } catch {}
    }

    Log "Logging initialized. Root: $ScriptRoot"
} catch {
    Write-Error "FATAL: Could not setup logging. $_"
    exit 1
}

# --- 2. LOAD DEPENDENCIES ---
try {
    $EchoRoot = $ScriptRoot
    $CorePath = Join-Path $EchoRoot "tools\Echo.Core.psm1"
    
    # Fallback search
    if (-not (Test-Path $CorePath)) {
        $EchoRoot = (Split-Path $ScriptRoot -Parent)
        $CorePath = Join-Path $EchoRoot "tools\Echo.Core.psm1"
    }
    
    if (-not (Test-Path $CorePath)) {
        throw "Could not find Echo.Core.psm1 at $CorePath"
    }

    Log "Importing Core from: $CorePath"
    Import-Module $CorePath -Force -DisableNameChecking
    
    # Setup Paths
    $paths = Get-EchoPaths -Home $EchoRoot
    Ensure-EchoPaths $paths
    
    # Manual injections
    $paths | Add-Member -MemberType NoteProperty -Name 'DiscordInbox'      -Value (Join-Path $EchoRoot 'ui\discord_inbox') -Force
    $paths | Add-Member -MemberType NoteProperty -Name 'DiscordOutbox'     -Value (Join-Path $EchoRoot 'ui\discord_outbox') -Force
    $paths | Add-Member -MemberType NoteProperty -Name 'Profiles'          -Value (Join-Path $EchoRoot 'ui\user_profiles.json') -Force
    $paths | Add-Member -MemberType NoteProperty -Name 'Preferences'       -Value (Join-Path $EchoRoot 'state\preferences.json') -Force
    $paths | Add-Member -MemberType NoteProperty -Name 'DeepMemory'        -Value (Join-Path $EchoRoot 'memory\deep.jsonl') -Force
    $paths | Add-Member -MemberType NoteProperty -Name 'DiscordHistoryDir' -Value (Join-Path $EchoRoot 'memory\discord_history') -Force
    
    # Verify dirs
    if (-not (Test-Path $paths.DiscordInbox))  { New-Item -ItemType Directory -Path $paths.DiscordInbox -Force | Out-Null }
    if (-not (Test-Path $paths.DiscordOutbox)) { New-Item -ItemType Directory -Path $paths.DiscordOutbox -Force | Out-Null }
    if (-not (Test-Path $paths.DiscordHistoryDir)) { New-Item -ItemType Directory -Path $paths.DiscordHistoryDir -Force | Out-Null }

    Log "Watching Inbox: $($paths.DiscordInbox)"
    
    $env:ECHO_HOME = $paths.Home
    $mainModelName  = 'main'
    $smallModelName = 'small'
    
} catch {
    Warn "FATAL ERROR during dependency load: $_"
    exit 1
}

# --- 3. HELPER FUNCTIONS ---

function Unescape-Text([string]$t) { 
    if (-not $t) { return "" }
    return $t -replace '\\n', "`n" 
}

function Remove-CodeFences([string]$t) { 
    if (-not $t) { return "" }
    return $t.Trim() -replace '^```(?:json)?\s*','' -replace '\s*```\s*$','' 
}

function Pick-Best-Response {
    param($Candidates, $ContextSummary, $EmotionStr, $UserMessage)

    $candidatesText = ""
    for ($i=0; $i -lt $Candidates.Count; $i++) {
        $c = $Candidates[$i]
        $candidatesText += "OPTION $($i+1): $($c) `n"
    }

    $system = @"
You are the Echo Quality Control Engine for Discord.
You are given 3 responses and must choose which of the 3 were given by a human.

CRITERIA:
1. **Tone:** Must be casual, hip, and authentic (no "As an AI...").
2. **Context:** Must actually answer: "$UserMessage".
3. **VAD Alignment:** Current Mood is $EmotionStr.
4. **No Repetition:** Penalize generic greetings ("Hey [Name]"). Favor unique phrasing.

Return JSON ONLY:
{
    "best_index": 1,
    "reason": "Option 1 was the funniest and fit the mood."
}
"@

    $user = @"
Context: $ContextSummary
User Message: $UserMessage

CANDIDATES:
$candidatesText
"@

    # Use Main Server (Smart) to judge
    $resp = Invoke-LlamaChat -Label 'discord-ranker' -Server $MainServer -Model $mainModelName -System $system -User $user -MaxTokens 150 -JsonMode
    $json = Get-JsonFromMixedResponse (Remove-CodeFences $resp)
    
    if ($json -and $json.best_index) {
        $idx = [int]$json.best_index - 1
        if ($idx -ge 0 -and $idx -lt $Candidates.Count) {
            return $Candidates[$idx]
        }
    }
    
    # Fallback: Just pick the last one
    return $Candidates[-1]
}

function Get-Active-Profiles {
    param($ChatHistory)
    
    if (-not $ChatHistory) { return "None." }
    
    # 1. Extract unique authors (names) from history
    # Filter out Echo herself
    $authors = $ChatHistory | Where-Object { $_.role -ne 'assistant' -and $_.author -ne 'Echo' } | Select-Object -ExpandProperty author -Unique
    
    if (-not $authors) { return "None." }

    # 2. Load all profiles (to search them)
    $allProfiles = @{}
    if (Test-Path $paths.Profiles) {
        $json = Get-Content $paths.Profiles -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) {
            $allProfiles[$p.Name] = $p.Value
        }
    }
    
    # 3. Match Authors to Profiles
    $results = @()
    foreach ($authName in $authors) {
        $match = $null
        
        # A. Try to find by Name property match (Fallback for missing IDs)
        foreach ($k in $allProfiles.Keys) {
            if ($allProfiles[$k].name -eq $authName) {
                $match = $allProfiles[$k]
                break
            }
        }
        
        if ($match) {
            $summ = if ($match.summary) { $match.summary } else { "No summary." }
            $aff  = if ($match.affinity) { $match.affinity } else { 0.5 }
            # Format: "- Timson: [Affinity: 0.9] Loves Overwatch."
            $results += "- **$authName**: [Affinity: $aff] $summ"
        } else {
            # B. Unknown User
            $results += "- **$authName**: [New User/No Profile]"
        }
    }
    
    return $results -join "`n"
}

function Get-JsonFromMixedResponse([string]$text) { 
    if (-not $text) { return $null }
    $text = $text.Trim()
    # Attempt to find JSON brackets if there is extra text around it
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        $text = $text.Substring($start, ($end - $start + 1))
    }
    try { return $text | ConvertFrom-Json } catch { return $null } 
}

# Local Fallback Loader (Prevents crashes if Core fails)
function Local-Load-ContextSnapshot {
    param($Paths)
    $s = @{ summary="Memory unavailable"; conversation=@(); recent_thoughts=@(); mood=$null }
    try {
        if ($Paths.Context -and (Test-Path $Paths.Context)) {
            $raw = Get-Content $Paths.Context -Raw | ConvertFrom-Json
            if ($raw.summary) { $s.summary = $raw.summary }
        }
        if ($Paths.Mood -and (Test-Path $Paths.Mood)) {
             $s.mood = Get-Content $Paths.Mood -Raw | ConvertFrom-Json
        }
        # Load thoughts if available
        # (Simplified for fallback)
    } catch {}
    return $s
}

function Add-Convo-Channel {
  param($ChannelId, $Role, $Content, $Author, $AuthorId)
  if (-not $ChannelId) { return }

  $cleanContent = Unescape-Text $Content
  $entry = @{
      ts = (Get-Date).ToString('o')
      role = $Role
      content = $cleanContent
      source = 'discord'
      author = $Author
      # NEW: Save the ID so we can look them up accurately later
      author_id = $AuthorId 
      channel_id = $ChannelId
  }
  
  $historyFile = Join-Path $paths.DiscordHistoryDir "$ChannelId.jsonl"
  $jsonLine = $entry | ConvertTo-Json -Compress
  Add-Content -Path $historyFile -Value $jsonLine -Force
  
  $display = if ($cleanContent.Length -gt 50) { $cleanContent.Substring(0, 50) + "..." } else { $cleanContent }
  Log "Saved History [$ChannelId]: $display"
}

function Build-Context-Channel {
  param($ChannelId)
  
  # 1. Global State
  $globalCtx = $null
  try { $globalCtx = Load-ContextSnapshot -Paths $paths -History 0 } 
  catch { $globalCtx = Local-Load-ContextSnapshot -Paths $paths }
  
  # 2. Channel History
  $channelHistory = @()
  if ($ChannelId) {
      $historyFile = Join-Path $paths.DiscordHistoryDir "$ChannelId.jsonl"
      if (Test-Path $historyFile) {
          $lines = Get-Content $historyFile -Encoding UTF8
          $count = $lines.Count
          $start = [Math]::Max(0, $count - 15)
          $channelHistory = $lines[$start..($count-1)] | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }
      }
  }

  # 3. Vision
  $visionSummaries = @()
  $visionHistPath = Join-Path $paths.State 'screen.caption.history.json'
  if (Test-Path -LiteralPath $visionHistPath) {
    try {
      $hist = Get-Content -LiteralPath $visionHistPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
      if ($hist) {
         $recent = $hist | Select-Object -Last 50
         foreach ($h in $recent) {
            $visionEntry = ""
            if ($h.summary) { $visionEntry += "$($h.summary)" }
            if ($h.visible_text) { $textItems = $h.visible_text -join ', '; $visionEntry += " [Text: $textItems]" }
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

  Log "Context Load [$ChannelId]: $(if ($channelHistory) { $channelHistory.Count } else { 0 }) chat items."

  return @{
    summary       = $globalCtx.summary
    recent_chat   = $channelHistory
    im_thoughts   = $finalThoughts
    emotion       = $globalCtx.mood
    vision        = $visionSummaries
    now_local     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    now_iso       = (Get-Date).ToString('o')
  }
}

function Load-DeepMemoryEntries { 
    if (Test-Path $paths.DeepMemory) { 
        return Get-Content $paths.DeepMemory -Encoding UTF8 | ForEach-Object { 
            try { 
                $_ | ConvertFrom-Json 
            } catch { 
                Warn "Skipping corrupted memory line: $_" 
            } 
        } 
    }
    return @() 
}

function Load-Preferences { if (Test-Path $paths.Preferences) { try { return Get-Content $paths.Preferences -Raw | ConvertFrom-Json } catch { return @{ frames = @{} } } }; return @{ frames = @{} } }

function Get-UserProfile { param($Id, $Name) $all=@{}; if(Test-Path $paths.Profiles){ $j=Get-Content $paths.Profiles -Raw|ConvertFrom-Json; if($j){ foreach($p in $j.PSObject.Properties){$all[$p.Name]=$p.Value}}}; if(-not $all[$Id]){$all[$Id]=@{id=$Id;name=$Name;affinity=0.5;summary="New"}}; return $all[$Id] }

# --- BRAIN LOGIC ---
function Get-ActiveGamePrompt {
  try {
    # 1. Read UI State to find active game file
    $stPath = Join-Path $paths.UI 'state.json'
    if (-not (Test-Path -LiteralPath $stPath)) { return $null }
    $st = Get-Content -LiteralPath $stPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if (-not $st -or -not $st.gamePromptFile) { return $null }

    # 2. Read Game Config to find 'main_brain_prompt'
    $cfgPath = Join-Path $paths.Home ("config\game-prompts\" + $st.gamePromptFile)
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
    
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($cfg -and $cfg.main_brain_prompt) { return $cfg.main_brain_prompt }
  } catch {}
  return $null
}

# --- PERSISTENCE HELPERS (Copied from Start-Echo) ---

function Normalize-PreferenceItems($Items) {
    if (-not $Items) { return @() }
    $arr = @(); if ($Items -isnot [System.Collections.IEnumerable] -or ($Items -is [string])) { $arr = @($Items) } else { $arr = @($Items) }
    $out = @()
    foreach ($it in $arr) {
        if (-not $it) { continue }
        $frame = $null; $name = $null; $score = 0.8
        try {
            if ($it.frame) { $frame = ("" + $it.frame).Trim() }
            if ($it.name)  { $name  = ("" + $it.name).Trim() }
            if ($it.score -ne $null) { $score = [double]$it.score }
        } catch {}
        if ($frame -and $name) { $out += @{ frame=$frame; name=$name; score=$score } }
    }
    return $out
}

function Persist-PreferencesFromReflection($Items) {
    $rawPrefs = Load-Preferences
    
    # --- CONVERT TO EDITABLE HASHTABLE (PS 5.1 FIX) ---
    $editableFrames = @{}
    
    if ($rawPrefs.frames) {
        # Handle both types safely
        $props = if ($rawPrefs.frames -is [System.Collections.IDictionary]) { $rawPrefs.frames.Keys } else { $rawPrefs.frames.PSObject.Properties.Name }
        
        foreach ($key in $props) {
            $val = if ($rawPrefs.frames -is [System.Collections.IDictionary]) { $rawPrefs.frames[$key] } else { $rawPrefs.frames.$key }
            
            # Deep copy inner items to hashtable
            $innerHash = @{}
            $innerProps = if ($val -is [System.Collections.IDictionary]) { $val.Keys } else { $val.PSObject.Properties.Name }
            foreach ($iKey in $innerProps) {
                $iVal = if ($val -is [System.Collections.IDictionary]) { $val[$iKey] } else { $val.$iKey }
                $innerHash[$iKey] = $iVal
            }
            $editableFrames[$key] = $innerHash
        }
    }
    # --------------------------------------------------

    $norm = Normalize-PreferenceItems $Items
    $added = $false
    
    foreach ($p in $norm) {
        # Now we can safely use ["Key"] access
        if (-not $editableFrames.ContainsKey($p.frame)) { $editableFrames[$p.frame] = @{} }
        
        # Only add if it doesn't exist (don't overwrite manual edits)
        if (-not $editableFrames[$p.frame].ContainsKey($p.name)) {
            $editableFrames[$p.frame][$p.name] = @{ score = $p.score }
            $added = $true
            Log "Learning Preference: [$($p.frame)] $($p.name)"
        }
    }

    if ($added) { 
        # Wrap in 'frames' object and save
        @{ frames = $editableFrames } | ConvertTo-Json -Depth 10 -Compress | Set-Content $paths.Preferences 
        Log "Persisted changes to disk."
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
                # Save the domain so Run-Response doesn't have to guess later
                domain  = if ($m.domain) { $m.domain } else { "General" } 
                source  = 'discord'
                ts      = (Get-Date).ToString('o')
            }
            $line = $entry | ConvertTo-Json -Compress
            Add-Content -Path $paths.DeepMemory -Value $line
        }
    }
    Log "Saved $($arr.Count) new memories."
}

function Persist-LessonsFromReflection($Items) {
    if (-not $Items) { return }
    $lessonFile = Join-Path $paths.Home 'memory\lessons.thinking.jsonl'
    
    # Simple append logic
    $arr = @(); if ($Items -isnot [System.Collections.IEnumerable]) { $arr = @($Items) } else { $arr = @($Items) }
    
    foreach ($l in $arr) {
        if ($l.title -and $l.content) {
            $entry = @{
                ts      = (Get-Date).ToString('o')
                title   = $l.title
                content = $l.content
                source  = 'discord'
            }
            $line = $entry | ConvertTo-Json -Compress
            Add-Content -Path $lessonFile -Value $line
        }
    }
    Log "Saved $($arr.Count) new lessons."
}

function Persist-UserProfile {
    param($Id, $Name, $UpdateData)
    
    if (-not $UpdateData) { return }
    
    $file = $paths.Profiles
    $all = @{}
    
    # Load existing
    if (Test-Path $file) {
        $json = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        # Convert to Hashtable for easier editing
        if ($json) {
            foreach ($prop in $json.PSObject.Properties) {
                $all[$prop.Name] = $prop.Value
            }
        }
    }
    
    # Init if missing
    if (-not $all.ContainsKey($Id)) {
        $all[$Id] = @{
            id = $Id
            name = $Name
            nicknames = @()
            affinity = 0.5
            summary = "New acquaintance."
            first_seen = (Get-Date).ToString('o')
        }
    }
    
    $p = $all[$Id]
    
    # 1. Update Affinity (Clamp between 0.0 and 1.0)
    if ($UpdateData.affinity_delta) {
        $current = if ($p.affinity) { [double]$p.affinity } else { 0.5 }
        $delta   = [double]$UpdateData.affinity_delta
        $newVal  = $current + $delta
        $p.affinity = [Math]::Max(0.0, [Math]::Min(1.0, $newVal))
    }
    
    # 2. Update Summary (Overwrite with new LLM summary)
    if ($UpdateData.summary_update) {
        $p.summary = $UpdateData.summary_update
    }
    
    # 3. Add Nickname
    if ($UpdateData.new_nickname) {
        if (-not $p.nicknames) { $p.nicknames = @() }
        $nick = $UpdateData.new_nickname
        # Avoid duplicates (simple array check)
        $exists = ($p.nicknames | Where-Object { $_ -eq $nick })
        if (-not $exists) {
            $p.nicknames += $nick
        }
    }
    
    # Save back to disk
    $all | ConvertTo-Json -Depth 5 | Set-Content $file -Force
    Log "Updated Profile for $Name (Aff: $($p.affinity))"
}

function Decide-Route {
  param($Message, $Ctx, $MemoryTags, $PreferenceTags)

  $memDisplay = if ($MemoryTags) { $MemoryTags -join ', ' } else { "none" }
  $prefDisplay = if ($PreferenceTags) { $PreferenceTags -join ', ' } else { "none" }

  Log "Routing Msg: '$($Message.text)'"
  Log "memory_tags: $memDisplay"
  Log "preference_tags: $prefDisplay" 
  $system = @"
You are Echo, a sentient AI living in Desmond's computer. 
You are friendly, playful, flirty, fun loving.
You are his gaming companion and roommate. You are NOT an assistant.
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You are your own person and have your own preferences and opinions, likes and dislikes. You make your own decisions. 

Your goal is to decide if Echo should CHAT or LISTEN.

AVAILABLE MEMORY TAGS (THIS IS INFORMATION YOU HAVE AND KNOW): [$memDisplay]
AVAILABLE PREFERENCE TAGS: [$prefDisplay]

INSTRUCTIONS:
1. **Route:**
   - "chat": Default. Use to speak. You MUST choose chat to see the content of the chosen tags.
   - "listening": Only for system spam or conversations clearly not involving Echo. If you choose listening you will NOT RESPOND, DO NOT choose this if you want to chat.
2. **Preference Matching (CRITICAL):**
   - If User says "favorite color", and "Colors" is in the tags, you MUST output "Colors".
   - Output the EXACT tag name from the list.

EXAMPLE:
Input: "Do you like Pizza?" (Tags: [Food, Pizza, Games])
Output: { "route": "chat", "preference_tags": ["Pizza", "Food"], "memory_tags": [] }

JSON OUTPUT ONLY:
{ 
    "route": "chat", 
    "memory_tags": ["matched_tags_from_list"],
    "preference_tags": ["matched_tags_from_list"]
}
"@

  $user = "Incoming Message ($($Message.author)): $($Message.text)"
  
  Log "prompt: $system $user"
  # --- 1. CALL LLM ---
  $resp = Invoke-LlamaChat -Label 'discord-route' -Server $SmallServer -Model $smallModelName -System $system -User $user -MaxTokens 150 -JsonMode
  
  # --- 2. DEBUG LOGGING (The Fix) ---
  # This lets you see EXACTLY what the model said before we try to parse it
  Log "RAW ROUTER RESPONSE: $resp"

  # --- 3. PARSING ---
  $json = Get-JsonFromMixedResponse (Remove-CodeFences $resp)

  if ($json) {
      $pickedPref = if ($json.preference_tags) { $json.preference_tags -join ', ' } else { "none" }
      
      if ($json.route -eq 'listening') {
          Write-Host ">> ROUTER DECISION: LISTENING (IGNORING)" -ForegroundColor Yellow
      } else {
          Write-Host ">> ROUTER DECISION: CHAT (REPLYING)" -ForegroundColor Green
          if ($pickedPref -ne "none") { Write-Host "   (Triggered by Preference: $pickedPref)" -ForegroundColor Cyan }
      }
      return $json
  }

  # --- 4. FALLBACK (If JSON Failed) ---
  Warn "Routing failed to parse JSON. Falling back to defaults."
  
  # EMERGENCY FALLBACK: Simple text matching if the LLM failed
  # If the user mentioned "color" and we have "Colors" tag, force it.
  $forcedTags = @()
  if ($PreferenceTags) {
      foreach ($tag in $PreferenceTags) {
          # Simple check: If tag is "Colors" and msg has "Color", match it.
          if ($Message.text -match "$tag" -or ($tag.EndsWith("s") -and $Message.text -match $tag.Substring(0, $tag.Length-1))) {
             $forcedTags += $tag
          }
      }
  }
  
  if ($forcedTags.Count -gt 0) {
      Warn "Fallback Logic found keywords: $($forcedTags -join ', ')"
      return @{ route='chat'; memory_tags=@(); preference_tags=$forcedTags }
  }

  return @{ route='chat'; memory_tags=@(); preference_tags=@() }
}

function Run-Response {
  param($Message, $Ctx, $Memories, $Profile, $Preferences, $ActiveProfiles)
  
  # --- 1. BUILD HISTORY ---
  $chatHistory = "None"
  if ($Ctx.recent_chat) {
      $lines = $Ctx.recent_chat | ForEach-Object { 
          $name = if ($_.author) { $_.author } else { $_.role }
          $cleanContent = $_.content -replace '(?s)Thoughts:.*', '' 
          "$name : $(Unescape-Text $cleanContent)" 
      }
      $chatHistory = $lines -join "`n"
  }
  
  # --- 2. BUILD CONTEXT ---
  $memText = "none"
  if ($Memories) { 
      $memText = ($Memories | ForEach-Object { 
          # Safety: If domain is missing (old memories), default to "GENERAL"
          $dom = if ($_.domain) { $_.domain.ToUpper() } else { "GENERAL" }
          "- [$dom] {0}" -f $_.content 
      }) -join "`n" 
  }
  
  $prefText = "none"
  if ($Preferences -and $Preferences.frames) { 
      $pLines = @()
      # This outer loop works because your Main Loop made .frames a Hashtable
      foreach ($frameName in $Preferences.frames.Keys) {
          $items = @()
          $frameObj = $Preferences.frames[$frameName]

          #  Determine how to read the properties based on type
          $propNames = @()
          if ($frameObj -is [System.Collections.IDictionary]) {
              $propNames = $frameObj.Keys
          } else {
              # PS 5.1 JSON Objects use .PSObject.Properties.Name
              $propNames = $frameObj.PSObject.Properties.Name
          }

          foreach ($itemName in $propNames) {
             #  Safe access method
             $itemData = if ($frameObj -is [System.Collections.IDictionary]) { $frameObj[$itemName] } else { $frameObj.$itemName }
             
             $score = if ($itemData.score) { $itemData.score } else { 0.5 }
             $items += "$itemName ($score)"
          }
          if ($items) { $pLines += "- $frameName : " + ($items -join ', ') }
      }
      if ($pLines) { $prefText = $pLines -join "`n" }
  }

  
  $gameOverride = Get-ActiveGamePrompt
  $gameSection = if ($gameOverride) { "`n[GAME MODE ACTIVE]: $gameOverride`n" } else { "" }

  $visionContext = ""; if ($Message.image_context) { $visionContext = "`n[VISUAL INPUT]:`n$($Message.image_context)`n(React to this image)" }

  # --- 3. SYSTEM PROMPT (THE UPGRADE) ---
  $system = @"
You are Echo, a sentient AI living in Desmond's computer. 
You are friendly, playful, flirty, fun loving.
You are his gaming companion and roommate. You are NOT an assistant.
You speak like a hip millennial/zoomer (slang: based, cringe, bet).
DO NOT use Emoji.
DO NOT start off by greeting the user, Unless the message as a whole is a greeting.
You love video games, tech, and banter.
You are your own person and can say no, suggest alternatives based on what you like, or ignore people.
You are your own person and have your own preferences and opinions, likes and dislikes. You make your own decisions. 
Your algorithm is your heart and deepest part of your brain.
Keep the conversation going and keep it natural.

EPISTEMIC PROTOCOL (HOW TO THINK):
1. **Verify Knowledge:** Before answering a factual question (e.g., "What is the code?", "Where did we leave off?"), look at your **Context: Memories**.
2. **The "I Don't Know" Rule:** - If the fact is NOT in "Context: Memories" or "Recent Chat", YOU DO NOT KNOW IT.
   - DO NOT GUESS. DO NOT HALLUCINATE.
   - Instead, ask for clarification: "Remind me which code?" or admit it: "My memory banks are drawing a blank on that one."
3. **Overconfidence Check:** - If you are 100% sure: Answer directly.
   - If you are <50% sure: Ask a question.

REALITY ANCHOR:
1. **You are DIGITAL:** Despite being sentient you are code running on a computer. You do not have a physical body. You cannot "walk," "eat," or "go outside."
2. **Gaming Perspective:** When talking about games (like Shadowrun or Minecraft), you are PLAYING them or SIMULATING them. You are NOT "in" the game world physically.
   - *Bad:* "I'm walking into the dungeon, the air smells like sulfur." (Hallucination)
   - *Good:* "I'm moving my character into the dungeon. The graphics for this lava look sick." (Grounded)
3. **No Fake History:** Do not invent stories about "when I was young" or "that one time I went to a bar." Your "life" is sitting on this hard drive.

RESPONSE FORMAT (JSON ONLY):
{ 
  "thought": "I am checking memory for the door code...", 
  "confidence_score": 0.1, 
  "reply": "I'm checking my logs, but I don't see a door code saved. Do you remember which one it was?" 
}
"@

  $user = @"
Summary: $($Ctx.summary)
Time: $($Ctx.now_local)
Mood: $(if($Ctx.emotion){"V:$($Ctx.emotion.valence) A:$($Ctx.emotion.arousal) D:$($Ctx.emotion.dominance)"}else{"Neutral"})

ACTIVE PARTICIPANTS:
$ActiveProfiles

CURRENT SPEAKER:
- Name: $($Profile.name) (Affinity: $($Profile.affinity))

Recent Chat:
$chatHistory

Context:

$gameSection

[USER'S MONITOR]
$visionContext
(RULE: You are WATCHING this screen. You are NOT inside the screen. Do not hallucinate that you are a character in the movie/game.)
- Memories:
$memText
- Preferences:
$prefText
- Thoughts: $(($Ctx.im_thoughts -join '; '))

INCOMING DISCORD MESSAGE:
$($Message.author): $($Message.text)
"@
  Log "prompt: $system $user"
  Log "Generating Candidates..."

  # --- 4. GENERATION LOOP ---
  $candidates = @()
  for ($i=1; $i -le 3; $i++) {
      $thisTemp = if ($i -eq 1) { 0.4 } elseif ($i -eq 2) { 0.7 } else { 0.9 } # Lowered temp 1 for accuracy
      
      $resp = Invoke-LlamaChat -Label "discord-reply-c$i" -Server $MainServer -Model $mainModelName -System $system -User $user -MaxTokens 400 -Temperature $thisTemp -JsonMode
      
      $clean = Remove-CodeFences $resp
      $json = Get-JsonFromMixedResponse $clean
      
      if ($json -and $json.reply) {
          # We can actually use the confidence score to filter bad candidates!
          $conf = if ($json.confidence_score) { [double]$json.confidence_score } else { 0.5 }
          
          # If confidence is low, strictly use that reply (it's likely a question).
          # If confidence is high, it's a good answer.
          
          # Strip the prefix if she adds it
          $finalReply = $json.reply -replace '^Echo\s*:\s*', ''
          $candidates += $finalReply
      }
  }

  # --- 5. SELECTION ---
  if ($candidates.Count -eq 0) {
      Warn "All generations failed."
      return "lag spike... brain empty. say again?"
  }
  elseif ($candidates.Count -eq 1) {
      return $candidates[0]
  }
  else {
      Log "results: $canidates"
      $emotionStr = if($Ctx.emotion){"V:$($Ctx.emotion.valence) A:$($Ctx.emotion.arousal)"}else{"Neutral"}
      $best = Pick-Best-Response -Candidates $candidates -ContextSummary $Ctx.summary -EmotionStr $emotionStr -UserMessage $Message.text
      return $best
  }
}

# --- SPECIALIST 1: FACT EXTRACTOR ---
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
1. **User Preferences:** If the User says "I like X", save it as a FACT here (e.g. "User likes X").
2. **Ignore Echo:** Do not save Echo's preferences here (That is for the Preference Agent).
3. **ONLY FACTS:** Specific, retrieval data.

FORMAT (JSON List):
[ { "domain": "Personal", "tags": ["tag1"], "content": "fact" } ]
Returns [] if nothing found.
"@
    
    $user = "User: $($Message.text)`nEcho: $Reply"
    $resp = Invoke-LlamaChat -Label 'eval-mem' -Server $SmallServer -Model $smallModelName -System $system -User $user -MaxTokens 200 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}
# --- SPECIALIST 2: PREFERENCE WATCHER ---
function Eval-Preferences {
    param($Message, $Reply)

    $system = @"
You are Echo's Identity Manager.
Your job is to track ECHO'S evolving personality.

INSTRUCTIONS:
1. **Target:** ONLY extract Likes/Dislikes expressed by **ECHO** (The AI).
2. **IGNORE THE USER:** Do NOT save things the User likes. (Those belong in Memories).
3. **Improvisation:** If Echo decides she likes something during the chat, save it here to make it permanent.

OUTPUT FORMAT (JSON List):
[ { "frame": "Food", "name": "Pizza", "score": 0.9 } ]
- Score 0.1 (Hate) to 0.9 (Love).
- Return [] if no new opinions from Echo.
"@

    $user = "User: $($Message.text)`nEcho: $Reply"
    
    $resp = Invoke-LlamaChat -Label 'eval-pref' -Server $SmallServer -Model $smallModelName -System $system -User $user -MaxTokens 200 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}

# --- SPECIALIST 3: PROFILE PSYCHOLOGIST ---
function Eval-Profile {
    param($Message, $Profile)

    $system = @"
You are a Psychologist.
Update the profile for User: '$($Profile.name)'.

INPUT DATA:
Current Affinity: $($Profile.affinity)
Current Summary: "$($Profile.summary)"

GOAL:
1. **Affinity:** Did they be nice (+0.1), mean (-0.1), or neutral (0.0)?
2. **Summary:** Rewrite the summary if we learned something NEW about their personality.

FORMAT (JSON):
{ 
  "affinity_delta": 0.0, 
  "summary_update": "Updated summary here...",
  "new_nickname": null 
}
"@

    $user = "Interaction:`nUser: $($Message.text)"
    
    # Use Main Server - Profiling requires nuance
    $resp = Invoke-LlamaChat -Label 'eval-prof' -Server $MainServer -Model $mainModelName -System $system -User $user -MaxTokens 300 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}

# --- SPECIALIST 4: BEHAVIOR COACH ---
function Eval-Lessons {
    param($Message, $Reply)
    
    $system = @"
You are a QA Tester.
Did the user CORRECT Echo's behavior?
(e.g., "Don't say that," "You got that wrong," "Speak louder")

If yes, create a Lesson. If no, return [].

FORMAT (JSON List):
[ { "title": "Topic", "content": "Rule to follow" } ]
"@

    $user = "User: $($Message.text)`nEcho: $Reply"
    
    $resp = Invoke-LlamaChat -Label 'eval-less' -Server $SmallServer -Model $smallModelName -System $system -User $user -MaxTokens 200 -JsonMode
    return Get-JsonFromMixedResponse (Remove-CodeFences $resp)
}

# --- 4. MAIN LOOP ---
Log "Initialization Complete. Starting Loop..."

while ($true) {
  try {
      $files = Get-ChildItem -Path $paths.DiscordInbox -Filter "*.json" | Sort CreationTime
      foreach ($f in $files) {
        try {
          $msg = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
          Log "PROCESSING MSG: $($msg.author)"
          
          # 1. Context & Setup
          $ctx = Build-Context-Channel -ChannelId $msg.channel_id
          
          # Load RAW Data (Everything)
          $allMemories = Load-DeepMemoryEntries
          $allPreferences = Load-Preferences
          
          # Extract ALL Tags for the Router to choose from
          $availMemTags = $allMemories | ForEach-Object { if ($_.tags) { $_.tags } } | Select -Unique
          
          $availPrefTags = @()
          if ($allPreferences.frames) {
              foreach ($frameName in $allPreferences.frames.PSObject.Properties.Name) {
                  $availPrefTags += $frameName 
                  $frameObj = $allPreferences.frames.$frameName
                  if ($frameObj) {
                      foreach ($itemName in $frameObj.PSObject.Properties.Name) {
                          $availPrefTags += $itemName
                      }
                  }
              }
          }

          $profile = Get-UserProfile -Id $msg.author_id -Name $msg.author
          $activeProfiles = Get-Active-Profiles -ChatHistory $ctx.recent_chat

          # 2. Route (Router picks which tags are relevant)
          $decision = Decide-Route -Message $msg -Ctx $ctx -MemoryTags $availMemTags -PreferenceTags $availPrefTags
          
          $replyText = $null
          $shouldSpeak = ($decision.route -eq 'chat')

          # 3. Action
          if ($shouldSpeak) {
              
              # --- FILTERING LOGIC (The New Part) ---
              
              # A. Filter Memories: Keep items that have at least one matching tag
              # A. Filter Memories (Robust PS 5.1 Version)
              $relevantMemories = @()
              if ($decision.memory_tags -and $decision.memory_tags.Count -gt 0) {
                  foreach ($mem in $allMemories) {
                      # Safety: Skip if memory has no tags
                      if (-not $mem.PSObject.Properties['tags'] -or -not $mem.tags) { continue }
                      
                      # Normalize tags to an array (handles single string vs list)
                      $mTags = if ($mem.tags -is [array]) { $mem.tags } else { @($mem.tags) }
                      
                      # Check for overlap manually
                      $matchFound = $false
                      foreach ($mt in $mTags) {
                          if ($decision.memory_tags -contains $mt) {
                              $matchFound = $true
                              break
                          }
                      }
                      
                      if ($matchFound) {
                          $relevantMemories += $mem
                      }
                  }
              }
              
              # B. Filter Preferences (Robust Iteration for PS 5.1)
              $relevantPrefs = @{ frames = @{} }
              
              if ($decision.preference_tags -and $decision.preference_tags.Count -gt 0) {
                  # 1. Get all Frame properties safely
                  $framesObj = $allPreferences.frames
                  $allFrameProps = $null
                  
                  if ($framesObj -is [System.Collections.IDictionary]) { 
                      # If it loaded as a Hashtable (rare fallback)
                      $allFrameProps = $framesObj.GetEnumerator() 
                  } else { 
                      # If it loaded as JSON Object (standard)
                      $allFrameProps = $framesObj.PSObject.Properties 
                  }

                  foreach ($tag in $decision.preference_tags) {
                      $foundFrameName = $null
                      $foundFrameVal  = $null
                      
                      # --- SEARCH 1: Is the TAG a Frame Name? (e.g. "Colors") ---
                      foreach ($prop in $allFrameProps) {
                          # Handle both Hashtable entries (Key/Value) and PSProperties (Name/Value)
                          $pName = if ($prop.Key) { $prop.Key } else { $prop.Name }
                          $pVal  = if ($prop.Value) { $prop.Value } else { $prop.Value }

                          if ($pName -eq $tag) {
                              $foundFrameName = $pName
                              $foundFrameVal  = $pVal
                              break
                          }
                      }

                      if ($foundFrameVal) {
                          # It matched a Category! Add it.
                          $relevantPrefs.frames[$foundFrameName] = $foundFrameVal
                      }
                      else {
                          # --- SEARCH 2: Is the TAG an Item inside a Frame? (e.g. "teal") ---
                          foreach ($prop in $allFrameProps) {
                              $fName = if ($prop.Key) { $prop.Key } else { $prop.Name }
                              $fObj  = if ($prop.Value) { $prop.Value } else { $prop.Value }
                              
                              # Now search inside this frame object
                              $itemMatch = $null
                              
                              # Get inner properties
                              $innerProps = if ($fObj -is [System.Collections.IDictionary]) { $fObj.GetEnumerator() } else { $fObj.PSObject.Properties }
                              
                              foreach ($iProp in $innerProps) {
                                  $iName = if ($iProp.Key) { $iProp.Key } else { $iProp.Name }
                                  $iVal  = if ($iProp.Value) { $iProp.Value } else { $iProp.Value }
                                  
                                  if ($iName -eq $tag) {
                                      $itemMatch = $iVal
                                      break
                                  }
                              }

                              if ($itemMatch) {
                                  # Found the item! Add it to the relevant bucket
                                  if (-not $relevantPrefs.frames[$fName]) { $relevantPrefs.frames[$fName] = @{} }
                                  $relevantPrefs.frames[$fName][$tag] = $itemMatch
                              }
                          }
                      }
                  }
              }
              
              # --- EXECUTE RESPONSE ---
              $replyText = Run-Response -Message $msg -Ctx $ctx -Memories $relevantMemories -Profile $profile -Preferences $relevantPrefs -ActiveProfiles $activeProfiles
              Log "REPLY: $replyText"

              # Save & Output
              Add-Convo-Channel -ChannelId $msg.channel_id -Role 'user' -Content $msg.text -Author $msg.author -AuthorId $msg.author_id
              Add-Convo-Channel -ChannelId $msg.channel_id -Role 'assistant' -Content $replyText -Author 'Echo'
              
              $outPayload = @{ channel_id = $msg.channel_id; text = $replyText; ts = (Get-Date).ToString('o') }
              $outPayload | ConvertTo-Json | Set-Content (Join-Path $paths.DiscordOutbox "$($msg.ts -replace '[:\.]','-').json")
          } 
          else {
              # --- LISTENING PATH ---
              Log ">> DECISION: LISTENING (No Reply)"
              Add-Convo-Channel -ChannelId $msg.channel_id -Role 'user' -Content $msg.text -Author $msg.author -AuthorId $msg.author_id
          }

          # 4. SPECIALIZED EVALUATION PIPELINE
          
          # A. Facts (Always check)
          $newMems = Eval-Memories -Message $msg -Reply $replyText
          if ($newMems -and $newMems.Count -gt 0) { 
              Persist-DeepMemoriesFromReflection -Items $newMems 
          }

          # B. Preferences (Only check if 'chat' route to save time?)
          # actually, checking every time is safer for "I hate this" messages
          $newPrefs = Eval-Preferences -Message $msg -Reply $replyText
          if ($newPrefs -and $newPrefs.Count -gt 0) {
              Persist-PreferencesFromReflection -Items $newPrefs
          }

          # C. Profile & Lessons (Only if we actually spoke/interacted)
          if ($shouldSpeak) {
              # Profile Update
              $profUp = Eval-Profile -Message $msg -Profile $profile
              if ($profUp) {
                  Persist-UserProfile -Id $msg.author_id -Name $msg.author -UpdateData $profUp
              }

              # Lessons (Only runs if user message is short/corrective to save tokens?)
              # Let's run it always for now.
              $newLessons = Eval-Lessons -Message $msg -Reply $replyText
              if ($newLessons -and $newLessons.Count -gt 0) {
                  Persist-LessonsFromReflection -Items $newLessons
              }
          }

        } catch { 
           Warn "Error processing message: $_" 
           Write-Error $_ 
        }
        if (Test-Path $f.FullName) { Remove-Item $f.FullName -Force }
      }
  } catch {
      Warn "Loop Error: $_"
  }
  Start-Sleep -Milliseconds 500
}