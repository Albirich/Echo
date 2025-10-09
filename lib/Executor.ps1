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
              # Check if tags match
              $tagMatch = $false
              if ($Task.params.tags) {
                foreach ($tag in $Task.params.tags) {
                  if ($mem.tags -contains $tag) { $tagMatch = $true; break }
                }
              } else {
                $tagMatch = $true  # No tag filter
              }
              
              if ($tagMatch -and $mem.content) {
                $matches += $mem.content
              }
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
    [Parameter(Mandatory)]$Plan,  # Remove [object] or add it explicitly
    [string]$OutboxPath,
    [string]$HomeDir
  )
  
  $context = @{}
  $trace = @()
  
  # Phase 1: Info gathering (parallel concept - PowerShell runs sequentially but we gather all info first)
  if ($Plan.info_tasks) {
    foreach ($task in $Plan.info_tasks) {
      $result = Invoke-InfoTask -Task $task -HomeDir $HomeDir
      $context[$task.key] = $result
      $trace += @{
        phase = 'info_gathering'
        task = $task.key
        success = $result.success
        data_count = if ($result.data -is [array]) { $result.data.Count } else { 1 }
      }
    }
  }
  
  # Phase 2: Execute steps sequentially
  foreach ($step in $Plan.steps) {
    # Check dependencies
    if ($step.depends_on) {
      $missingDeps = @()
      foreach ($dep in $step.depends_on) {
        if (-not $context.ContainsKey($dep)) {
          $missingDeps += $dep
        }
      }
      
      if ($missingDeps.Count -gt 0) {
        $trace += @{
          phase = 'execution'
          step = $step.action
          skipped = $true
          reason = "Missing dependencies: $($missingDeps -join ', ')"
        }
        continue
      }
    }
    
    # Execute step
    $result = Invoke-PlanStep -Step $step -Context $context -OutboxPath $OutboxPath -HomeDir $HomeDir
    
    # Store result for next steps and branching
    $context[$step.action] = $result
    $context._last_result = $result
    
    $trace += @{
      phase = 'execution'
      step = $step.action
      success = $result.success
      skipped = $result.skipped
    }
    
    # Handle branching
    if ($result.success -and $step.on_success) {
      # Find and execute success branch
      $successStep = $Plan.steps | Where-Object { $_.action -eq $step.on_success } | Select-Object -First 1
      if ($successStep) {
        $branchResult = Invoke-PlanStep -Step $successStep -Context $context -OutboxPath $OutboxPath -HomeDir $HomeDir
        $context[$successStep.action] = $branchResult
        $trace += @{
          phase = 'execution'
          step = $successStep.action
          branch = 'success'
          success = $branchResult.success
        }
      }
    } elseif (-not $result.success -and $step.on_failure) {
      # Find and execute failure branch
      $failureStep = $Plan.steps | Where-Object { $_.action -eq $step.on_failure } | Select-Object -First 1
      if ($failureStep) {
        $branchResult = Invoke-PlanStep -Step $failureStep -Context $context -OutboxPath $OutboxPath -HomeDir $HomeDir
        $context[$failureStep.action] = $branchResult
        $trace += @{
          phase = 'execution'
          step = $failureStep.action
          branch = 'failure'
          success = $branchResult.success
        }
      }
    }
  }
  
  # Phase 3: Completion
  $completionMessage = $Plan.completion.message
  if ($Plan.completion.depends_on) {
    # Resolve completion message using context
    foreach ($dep in $Plan.completion.depends_on) {
      if ($context.ContainsKey($dep) -and $context[$dep].data) {
        # Simple replacement - could be more sophisticated
        $completionMessage = $completionMessage -replace "\[$dep\]", $context[$dep].data
      }
    }
  }
  
  return @{
    success = $true
    message = $completionMessage
    trace = $trace
    context = $context
  }
}