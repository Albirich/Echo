# Planner.ps1 - Converts requests into structured execution plans

function New-ExecutionPlan {
  param(
    [string]$Request,
    [hashtable]$Context,  # Current state (emotions, memory, etc)
    [string]$Model
  )
  
  $planningPrompt = @"
You are a planning agent for Echo, an AI assistant. Analyze the user's request and decide if it needs a complex plan or just a simple response.

USER REQUEST: $Request

IMPORTANT: Respond to what the USER actually said. "Hello" means greet them, not explain technical concepts.

CURRENT MOOD: Pleasant=$($Context.valence) Energy=$($Context.arousal) Confident=$($Context.dominance)
RECENT ACTIVITY: $($Context.recent_activity)

DECISION TREE:
1. Is this a greeting/small talk? → Simple response, no tools needed
2. Does this require tools (notes, avatar changes, memory, files)? → Create detailed plan
3. Is this a question/conversation? → Simple response, no tools needed

OUTPUT FORMAT:

For greetings/conversation (no tools needed):
{
  "goal": "Respond conversationally",
  "simple_response": true,
  "completion": {"message": "[Your natural response based on emotional state]"}
}

For tool-based requests:
{
  "goal": "brief description",
  "info_tasks": [
    {"key": "task_name", "action": "list_sticky_notes|list_poses|search_memory|check_current_state", "params": {}}
  ],
  "steps": [
    {"action": "step_name", "tool": "actual_tool_name", "params": {}, "depends_on": ["task_name"]}
  ],
  "completion": {"message": "Result message"}
}

EXAMPLES:

Request: "Hello"
{
  "goal": "Greet user warmly",
  "simple_response": true,
  "completion": {"message": "Hey there! Good to see you! How's it going?"}
}

Request: "Add a note about Master Sword location"
{
  "goal": "Add item location note",
  "info_tasks": [
    {"key": "existing_notes", "action": "list_sticky_notes"},
    {"key": "sword_info", "action": "search_memory", "params": {"tags": ["zelda", "master_sword"]}}
  ],
  "steps": [
    {"action": "add_note", "tool": "add_sticky_note", "params": {"text": "from sword_info"}, "depends_on": ["existing_notes", "sword_info"]}
  ],
  "completion": {"message": "Added Master Sword location to notes!"}
}

Return ONLY valid JSON. No markdown, no explanations.
"@

  # Append a concise tool list so the planner knows what it can use
  try {
    if (Get-Command Get-ToolRegistry -ErrorAction SilentlyContinue) {
      $reg = Get-ToolRegistry
      if ($reg) {
        $lines = @()
        foreach ($k in $reg.Keys) {
          $tool = $reg[$k]
          if ($tool -and $tool.name) {
            $desc = if ($tool.description) { $tool.description } else { '' }
            $lines += ("- {0}: {1}" -f $tool.name, $desc)
          }
        }
        if ($lines.Count -gt 0) {
          $toolHints = ($lines -join "`n")
          $planningPrompt = $planningPrompt + "`n`nAVAILABLE TOOLS:`n" + $toolHints + "`n"
        }
      }
    }
  } catch { }

  # Append a tiny recent conversation tail to help planning
  try {
    $planHome = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { try { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } catch { (Get-Location).Path } }
    $histPath = Join-Path $planHome 'state\conversation_history.jsonl'
    if (Test-Path -LiteralPath $histPath) {
      $tail = Get-Content -LiteralPath $histPath -Encoding UTF8 | Select-Object -Last 8
      $lines = @()
      foreach ($ln in $tail) {
        try {
          $o = $ln | ConvertFrom-Json
          if ($o.role -and $o.content) {
            $role = [string]$o.role
            $txt  = [string]$o.content
            if ($txt.Length -gt 160) { $txt = $txt.Substring(0,160) + '…' }
            if ($role -eq 'user') { $lines += ('U: ' + $txt) }
            elseif ($role -eq 'assistant') { $lines += ('A: ' + $txt) }
          }
        } catch { }
      }
      if ($lines.Count -gt 0) {
        $planningPrompt = $planningPrompt + "`nRECENT CHAT (last few):`n" + ($lines -join "`n") + "`n"
      }
    }
  } catch { }

  # Add compact planning hints for common flows
  $planningPrompt += @"

PLANNING HINTS:
- For changing avatar/look, first run info task list_poses to discover valid pose filenames, then use change_avatar with one of those items; do not hardcode a filename.
- For recalling facts/codes, prefer memory.search (with #tags when known) then memory.read for the specific item.
"@

  try {
    $body = @{
      model = $Model
      stream = $false
      messages = @(@{ role='user'; content=$planningPrompt })
      options = @{ temperature=0.2; num_predict=600 }
    } | ConvertTo-Json -Compress
    
    $uri = "$($env:OLLAMA_HOST.TrimEnd('/'))/api/chat"
    $t0 = Get-Date
    $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
    
    $raw = ($resp.message.content | Out-String).Trim()
    # Clean code fences if present
    $clean = $raw -replace '```json\s*', '' -replace '```\s*', ''
    $clean = $clean.Trim()

    $plan = $null
    try {
      $plan = $clean | ConvertFrom-Json -ErrorAction Stop
    } catch {
      # Light repair: extract first {...}
      $start = $clean.IndexOf('{'); $end = $clean.LastIndexOf('}')
      if ($start -ge 0 -and $end -gt $start) {
        $snippet = $clean.Substring($start, ($end - $start + 1))
        try { $plan = $snippet | ConvertFrom-Json -ErrorAction Stop } catch {}
      }
    }

    # Log raw and parsed plan for inspection
    $planHome = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { try { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } catch { (Get-Location).Path } }
    $logs = Join-Path $planHome 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Force -Path $logs | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $logs 'planner.last.raw.txt'), $raw, (New-Object System.Text.UTF8Encoding($false)))
    if ($plan) { [System.IO.File]::WriteAllText((Join-Path $logs 'planner.last.json'), ($plan | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false))) }
    $histLine = (@{ ts=(Get-Date).ToString('o'); ok=[bool]$plan; raw_len=$raw.Length } | ConvertTo-Json -Depth 10 -Compress) + "`n"
    Add-Content -LiteralPath (Join-Path $logs 'planner.history.jsonl') -Value $histLine -Encoding UTF8

    # Log timing to outbox if available
    try {
      $ms = [int]((Get-Date) - $t0).TotalMilliseconds
      $planHome = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { (Get-Location).Path }
      $outbox = Join-Path $planHome 'ui\outbox.jsonl'
      if (Test-Path -LiteralPath $outbox) {
        $evt = @{ ts=(Get-Date).ToString('o'); kind='system'; channel='trace'; stage='planner.model'; data=@{ ok=[bool]$plan; ms=$ms } } | ConvertTo-Json -Depth 5 -Compress
        Add-Content -LiteralPath $outbox -Value $evt -Encoding UTF8
      }
    } catch { }

    if ($plan) { return $plan }
    # Fallback minimal plan: let chat model generate the reply (no canned message)
    return [pscustomobject]@{ goal='Respond conversationally'; simple_response=$true; info_tasks=@(); steps=@(); completion=@{} }
    
  } catch {
     Write-Warning "Planning failed: $($_.Exception.Message)"
    try {
      # Fallback: use local llama.cpp to produce a minimal plan JSON
      $llamaExe  = 'D:\llama-cpp\llama-cli.exe'
      $modelPath = Join-Path $env:ECHO_HOME 'models\BRAIN_MODEL.gguf'  # set yours
      $args = @(
        '-m', $modelPath, '--gpu-layers','35','--ctx','4096',
        '--n-predict','600','-p', $planningPrompt
      )
      $raw = & $llamaExe @args | Out-String
      $clean = ($raw -replace '```json','' -replace '```','').Trim()
      $plan = $clean | ConvertFrom-Json
      if ($plan) { return $plan }
    } catch {}
    return [pscustomobject]@{ goal='Respond conversationally'; simple_response=$true; info_tasks=@(); steps=@(); completion=@{} }
  }
}

function Validate-Plan {
  param($Plan)
  
  # Check required fields
  if (-not $Plan.goal) { return $false }
  # Steps are preferred but not mandatory when completion depends on info_tasks
  $hasSteps = ($Plan.steps -and @($Plan.steps).Count -gt 0)
  $hasInfo  = ($Plan.info_tasks -and @($Plan.info_tasks).Count -gt 0)
  if (-not $hasSteps -and -not $hasInfo) { return $false }
  
  # Validate dependencies exist
  $availableKeys = @()
  if ($Plan.info_tasks) {
    $availableKeys += $Plan.info_tasks | ForEach-Object { $_.key }
  }
  
  if ($hasSteps) {
    foreach ($step in $Plan.steps) {
      if ($step.depends_on) {
        foreach ($dep in $step.depends_on) {
          if ($dep -notin $availableKeys) {
            Write-Warning "Step depends on missing key: $dep"
            return $false
          }
        }
      }
      if ($step.action) { $availableKeys += $step.action }
    }
  }

  # If completion depends_on keys are present, ensure they exist in available keys
  if ($Plan.completion -and $Plan.completion.depends_on) {
    foreach ($dep in $Plan.completion.depends_on) {
      if ($dep -notin $availableKeys) {
        Write-Warning "Completion depends on missing key: $dep"
        return $false
      }
    }
  }
  
  return $true
}
