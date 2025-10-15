# Executor.ps1 - Executes structured plans with parallel info gathering

function Invoke-InfoTask {
  param(
    [Parameter(Mandatory)]$Task,  # Remove [hashtable] type constraint
    [string]$HomeDir
  )
  
  $result = @{
    key = $Task.key
    success = $false
    data = $null
  }
  
  try {
    switch ($Task.action) {
      'list_sticky_notes' {
        $r = Invoke-ToolListStickyNotes -HomeDir $HomeDir
        $result.success = $r.success
        $result.data = $r.notes
      }
      
      'list_poses' {
        $standDir = Join-Path $HomeDir 'stand'
        $poses = @()
        if (Test-Path $standDir) {
          $dirs = Get-ChildItem $standDir -Directory
          foreach ($d in $dirs) {
            $pngs = Get-ChildItem $d.FullName -Filter '*.png' -File
            foreach ($p in $pngs) {
              $poses += "$($d.Name)/$($p.Name)"
            }
          }
        }
        $result.success = $true
        $result.data = $poses
      }
      
      'search_memory' {
        $memPath = Join-Path $HomeDir 'memory\deep.jsonl'
        $matches = @()
        if (Test-Path $memPath) {
          $lines = Get-Content $memPath -Encoding UTF8 | Select-Object -Last 200
          foreach ($line in $lines) {
            try {
              $mem = $line | ConvertFrom-Json
              # Normalize tags to an array of lowercase strings
              $memTags = @()
              if ($mem.tags -is [string]) { $memTags = @($mem.tags.ToLower()) }
              elseif ($mem.tags -is [System.Collections.IEnumerable]) { $memTags = @($mem.tags | ForEach-Object { "$_".ToLower() }) }

              # Check if tags match
              $tagMatch = $true
              if ($Task.params.tags) {
                $tagMatch = $false
                foreach ($tag in $Task.params.tags) {
                  $t = ("$tag").ToLower()
                  if ($memTags -contains $t) { $tagMatch = $true; break }
                }
              }

              if ($tagMatch -and $mem.content) { $matches += $mem.content }
            } catch {}
          }
        }
        $result.success = $true
        $result.data = $matches
      }
      
      'check_current_state' {
        # Read various state files
        $state = @{}
        
        # Emotion
        $emotionPath = Join-Path $HomeDir 'state\emotion.vad.json'
        if (Test-Path $emotionPath) {
          $state.emotion = Get-Content $emotionPath -Raw | ConvertFrom-Json
        }
        
        # Context
        $contextPath = Join-Path $HomeDir 'state\context.json'
        if (Test-Path $contextPath) {
          $state.context = Get-Content $contextPath -Raw | ConvertFrom-Json
        }
        
        $result.success = $true
        $result.data = $state
      }
      
      default {
        $result.success = $false
        $result.data = "Unknown info task: $($Task.action)"
      }
    }
  } catch {
    $result.success = $false
    $result.data = $_.Exception.Message
  }
  
  return $result
}

function Invoke-PlanStep {
  param(
    [Parameter(Mandatory)]$Step,  # Remove [hashtable] type constraint
    [hashtable]$Context,
    [string]$OutboxPath,
    [string]$HomeDir
  )
  
  # Check if step should run based on condition
  if ($Step.condition) {
    $shouldRun = switch ($Step.condition) {
      'previous_success' { $Context._last_result.success -eq $true }
      'previous_failure' { $Context._last_result.success -eq $false }
      default { $true }
    }
    
    if (-not $shouldRun) {
      return @{ success=$true; skipped=$true; reason="Condition not met: $($Step.condition)" }
    }
  }
  
  # Resolve parameters using context
  $params = @{}
  if ($Step.params) {
    foreach ($key in $Step.params.Keys) {
      $value = $Step.params[$key]
      
      # If value references context, resolve it
      if ($value -is [string] -and $value.StartsWith('from ')) {
        $contextKey = $value.Substring(5)  # Remove 'from '
        if ($Context.ContainsKey($contextKey)) {
          $value = $Context[$contextKey].data
        }
      }
      
      $params[$key] = $value
    }
  }

  # Special handling: change_avatar can accept a list from info phase
  if ($Step.tool -eq 'change_avatar' -and $params.ContainsKey('image')) {
    $imgVal = $params['image']
    if ($imgVal -is [System.Collections.IEnumerable] -and $imgVal -isnot [string]) {
      $list = @($imgVal)
      $preferred = ''
      if ($params.ContainsKey('preferred')) { $preferred = ("" + $params['preferred']).ToLower() }
      $chosen = $null
      if ($preferred) {
        $chosen = ($list | Where-Object { ("" + $_).ToLower() -match [regex]::Escape($preferred) } | Select-Object -First 1)
      }
      if (-not $chosen) { $chosen = ($list | Select-Object -First 1) }
      if ($chosen) {
        $params['image'] = [string]$chosen
      } else {
        # If list empty, let tool error naturally
        $params['image'] = $null
      }
      if ($params.ContainsKey('preferred')) { $params.Remove('preferred') }
    }
  }
  
  # Execute the tool
  if ($Step.tool) {
    return Invoke-Tool -ToolName $Step.tool -Parameters $params -OutboxPath $OutboxPath -HomeDir $HomeDir
  } elseif ($Step.action -eq 'update_shallow_memory') {
    return Invoke-ToolUpdateShallowMemory -HomeDir $HomeDir
  } else {
    return @{ success=$false; error="No tool specified for step: $($Step.action)" }
  }
}

function Execute-Plan {
  param(
    [Parameter(Mandatory)]$Plan,
    [string]$OutboxPath,
    [string]$HomeDir,
    [int]$HeartbeatSec = 6,
    [scriptblock]$InterruptCheck = $null
  )

  # Local helper: safe outbox append
  $append = {
    param($obj)
    try {
      if (Get-Command -Name Append-Outbox -ErrorAction SilentlyContinue) {
        Append-Outbox $obj
      } elseif ($OutboxPath) {
        $line = ($obj | ConvertTo-Json -Depth 30 -Compress)
        Add-Content -LiteralPath $OutboxPath -Value $line -Encoding UTF8
      }
    } catch { }
  }

  $context = @{}
  $trace = @()

  # Progress heartbeat ("mouth")
  $progress = @{ idx = 0; total = if ($Plan.steps) { @($Plan.steps).Count } else { 0 }; goal = $Plan.goal; started = Get-Date }
  $timer = $null; $evt = $null
  if ($HeartbeatSec -gt 0 -and $progress.total -gt 0) {
    try {
      $timer = New-Object System.Timers.Timer($HeartbeatSec * 1000)
      $timer.AutoReset = $true
      $evt = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
        try {
          $idx = $using:progress.idx + 1
          $tot = $using:progress.total
          $goal = [string]$using:progress.goal
          $msg = ('Working: step {0}/{1} - {2}' -f $idx, $tot, $goal)
          $line = (@{ ts=(Get-Date).ToString('o'); kind='assistant'; channel='mouth'; text=$msg } | ConvertTo-Json -Compress)
          if ($using:OutboxPath) { Add-Content -LiteralPath $using:OutboxPath -Value $line -Encoding UTF8 }
        } catch { }
      }
      $timer.Start()
    } catch { }
  }

  try {
    # Phase 1: Info gathering
    if ($Plan.info_tasks) {
      foreach ($task in $Plan.info_tasks) {
        $result = Invoke-InfoTask -Task $task -HomeDir $HomeDir
        $context[$task.key] = $result
        $trace += @{
          phase = 'info_gathering'
          task = $task.key
          success = $result.success
          data_count = if ($result.data -is [array]) { $result.data.Count } else { if ($null -eq $result.data) { 0 } else { 1 } }
        }
      }
    }

    # Phase 2: Execute steps sequentially with simple retry and interrupts
    $retries = 1
    for ($i = 0; $i -lt $progress.total; $i++) {
      $step = $Plan.steps[$i]
      $progress.idx = $i

      # Dependencies
      if ($step.depends_on) {
        $missingDeps = @()
        foreach ($dep in $step.depends_on) { if (-not $context.ContainsKey($dep)) { $missingDeps += $dep } }
        if ($missingDeps.Count -gt 0) {
          $trace += @{ phase='execution'; step=$step.action; skipped=$true; reason="Missing dependencies: $($missingDeps -join ', ')" }
          continue
        }
      }

      # Execute with one retry on failure
      $attempt = 0; $result = $null
      do {
        $attempt++
        $result = Invoke-PlanStep -Step $step -Context $context -OutboxPath $OutboxPath -HomeDir $HomeDir
        if ($result.success -or $attempt -gt $retries) { break }
      } while ($true)

      $context[$step.action] = $result
      $context._last_result = $result
      $trace += @{ phase='execution'; step=$step.action; success=$result.success; skipped=$result.skipped; attempts=$attempt }

      # Interrupt check between steps
      if ($InterruptCheck) {
        try {
          $intr = & $InterruptCheck
          if ($intr -and $intr.replan) {
            # Log and exit early for replan
            & $append @{ kind='system'; channel='brain'; event='interrupt.pivot'; reason=$intr.reason; message=$intr.new_message }
            return @{ success=$false; interrupted=$true; replan=$true; new_message=$intr.new_message; trace=$trace; context=$context }
          }
        } catch { }
      }

      # Branching
      if ($result.success -and $step.on_success) {
        $successStep = $Plan.steps | Where-Object { $_.action -eq $step.on_success } | Select-Object -First 1
        if ($successStep) {
          $branchResult = Invoke-PlanStep -Step $successStep -Context $context -OutboxPath $OutboxPath -HomeDir $HomeDir
          $context[$successStep.action] = $branchResult
          $trace += @{ phase='execution'; step=$successStep.action; branch='success'; success=$branchResult.success }
        }
      } elseif (-not $result.success -and $step.on_failure) {
        $failureStep = $Plan.steps | Where-Object { $_.action -eq $step.on_failure } | Select-Object -First 1
        if ($failureStep) {
          $branchResult = Invoke-PlanStep -Step $failureStep -Context $context -OutboxPath $OutboxPath -HomeDir $HomeDir
          $context[$failureStep.action] = $branchResult
          $trace += @{ phase='execution'; step=$failureStep.action; branch='failure'; success=$branchResult.success }
        }
      }
    }

    # Phase 3: Completion
    $completionMessage = $Plan.completion.message
    if ($Plan.completion.depends_on) {
      foreach ($dep in $Plan.completion.depends_on) {
        if ($context.ContainsKey($dep) -and $context[$dep].data) {
          $val = $context[$dep].data
          if ($val -is [array]) { $val = ($val -join ', ') }
          $completionMessage = $completionMessage -replace "\[$dep\]", [string]$val
        }
      }
    }

    return @{ success=$true; message=$completionMessage; trace=$trace; context=$context }
  } finally {
    # Stop heartbeat
    try { if ($timer) { $timer.Stop() } } catch {}
    try { if ($evt) { Unregister-Event -SourceIdentifier $evt.SourceIdentifier -ErrorAction SilentlyContinue } } catch {}
    try { if ($timer) { $timer.Dispose() } } catch {}
  }
}
