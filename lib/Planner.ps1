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

  try {
    $body = @{
      model = $Model
      stream = $false
      messages = @(@{ role='user'; content=$planningPrompt })
      options = @{ temperature=0.2; num_predict=600 }
    } | ConvertTo-Json -Compress
    
    $uri = "$($env:OLLAMA_HOST.TrimEnd('/'))/api/chat"
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

    if ($plan) { return $plan }
    # Fallback minimal plan to avoid full chat fallback path
    return [pscustomobject]@{ goal='Respond conversationally'; simple_response=$true; info_tasks=@(); steps=@(); completion=@{ message='Okay.' } }
    
  } catch {
    Write-Warning "Planning failed: $($_.Exception.Message)"
    # Fallback minimal plan to avoid chat fallback
    return [pscustomobject]@{ goal='Respond conversationally'; simple_response=$true; info_tasks=@(); steps=@(); completion=@{ message='Okay.' } }
  }
}

function Validate-Plan {
  param($Plan)
  
  # Check required fields
  if (-not $Plan.goal) { return $false }
  if (-not $Plan.steps) { return $false }
  
  # Validate dependencies exist
  $availableKeys = @()
  if ($Plan.info_tasks) {
    $availableKeys += $Plan.info_tasks | ForEach-Object { $_.key }
  }
  
  foreach ($step in $Plan.steps) {
    if ($step.depends_on) {
      foreach ($dep in $step.depends_on) {
        if ($dep -notin $availableKeys) {
          Write-Warning "Step depends on missing key: $dep"
          return $false
        }
      }
    }
    # Add this step's output to available keys
    if ($step.action) { $availableKeys += $step.action }
  }
  
  return $true
}
