<#
.SYNOPSIS
  Planner + executor loop for Echo's "thinking mode", using skills\manifest.json.

.DESCRIPTION
  - New-ThinkingPlan:
      Creates an initial step-by-step plan by calling the planner model.
      Saves plan_state as JSON on disk.

  - Invoke-ThinkingTick:
      Loads the plan_state.
      Executes exactly ONE step (tool_call or analysis) via the skills bus.
      Evaluates the result (adds our own semantics for certain tools).
      Sends result back to planner for possible replanning.
      Updates plan_state and history (3 phases per step: execute → evaluate → replan).

  Skills runtime:
    - Tools are described in skills\manifest.json
    - We talk to them via ui\skills.outbox.jsonl / ui\skills.inbox.jsonl
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("None", "Initial", "Tick")]
    [string]$Mode = "None",

    # For Initial
    [string]$Goal,
    [string]$ContextSummary,

    # For Tick
    [string]$LoopId,

    # Shared / defaults
    [string]$StateRoot = "$env:ECHO_ROOT\state\thinking",
    [string]$ToolsFile = "$env:ECHO_ROOT\skills\manifest.json",
    [string]$PlannerEndpoint = "http://127.0.0.1:8081/v1/chat/completions",
    [string]$PlannerModel = "planner-small",

    # Lessons
    [string]$LessonsFile = "$env:ECHO_ROOT\memory\lessons.thinking.jsonl"
)

# -------- Skill bus paths ----------------------------------------------------
$script:SkillOutbox = "$env:ECHO_ROOT\ui\skills.outbox.jsonl"
$script:SkillInbox  = "$env:ECHO_ROOT\ui\skills.inbox.jsonl"

if (-not (Test-Path (Split-Path $script:SkillOutbox))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $script:SkillOutbox) | Out-Null
}
if (-not (Test-Path (Split-Path $script:SkillInbox))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $script:SkillInbox) | Out-Null
}

# -------- Helper: append one JSONL line safely -------------------------------
function Write-JsonlLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Object
    )

    $line = $Object | ConvertTo-Json -Depth 10 -Compress
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Force -Path $Path | Out-Null
    }
    Add-Content -Path $Path -Value $line
}

function Get-LessonsForPlanner {
    param([string]$LessonsFile)

    if (-not (Test-Path $LessonsFile)) { return @() }
    $lines = Get-Content -Path $LessonsFile -ErrorAction SilentlyContinue
    $lessons = @()
    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            $lessons += $obj
        } catch {}
    }
    return $lessons
}

# -------- Helper: send skill request -----------------------------------------
function Send-SkillRequest {
    param(
        [pscustomobject]$Step,
        [pscustomobject]$PlanState
    )

    $requestId = [guid]::NewGuid().ToString()
    $now       = (Get-Date).ToString("o")

    $payload = @{
        type       = "skill_request"
        request_id = $requestId
        loop_id    = $PlanState.loop_id
        goal       = $PlanState.goal
        step_id    = $Step.id
        step_label = $Step.label
        skill      = $Step.tool      # e.g. "room.add_note", "memory.save"
        params     = $Step.params    # whatever planner provided
        created_at = $now
    }

    Write-JsonlLine -Path $script:SkillOutbox -Object $payload

    return $requestId
}

# -------- Helper: wait for skill response ------------------------------------
function Wait-SkillResponse {
    param(
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-Path $script:SkillInbox) {
            $lines = @(Get-Content -Path $script:SkillInbox -ErrorAction SilentlyContinue)
            if ($lines) {
                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    $line = $lines[$i]
                    if (-not $line.Trim()) { continue }

                    try {
                        $obj = $line | ConvertFrom-Json
                    }
                    catch {
                        continue
                    }

                    if ($obj.type -eq "skill_response" -and $obj.request_id -eq $RequestId) {
                        # Return raw result; we'll normalize per-tool later
                        return @{
                            success = [bool]$obj.success
                            error   = $obj.error
                            data    = $obj.data
                        }
                    }
                }
            }
        }

        Start-Sleep -Milliseconds 200
    }

    # Timeout
    return @{
        success = $false
        error   = "Timeout waiting for skill_response for request_id $RequestId"
        data    = $null
    }
}

# -------- Helper: normalize tool results (per-tool semantics) ----------------
function Normalize-ToolResult {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][hashtable]$Result
    )

    $success = [bool]$Result.success
    $errMsg  = $Result.error
    $data    = $Result.data

    # Special handling for memory.search:
    # Empty matches = failure, not silent success.
    if ($Tool -eq "memory.search") {
        $matches = $null
        if ($data -and ($data.PSObject.Properties.Name -contains "matches")) {
            $matches = $data.matches
        }

        if (-not $matches -or $matches.Count -eq 0) {
            $success = $false
            if (-not $errMsg) {
                $errMsg = "memory.search returned no results: no memories match this tag/text. If you’re sure it’s a memory, try a different tag; otherwise, use a different tool (e.g. list or room.*)."
            }
        }
    }

    return @{
        success = $success
        error   = $errMsg
        data    = $data
    }
}

# -------- Helper: ensure folders exist ---------------------------------------
if (-not (Test-Path $StateRoot)) {
    New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
}

# -------- Helper: load tools from skills\manifest.json -----------------------
function Get-PlannerTools {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Tools manifest file not found: $Path"
    }

    $json = Get-Content -Raw -Path $Path | ConvertFrom-Json

    if (-not $json.tools) {
        throw "Tools manifest does not contain a 'tools' array: $Path"
    }

    return $json.tools
}

# -------- Helper: call planner model -----------------------------------------
function Invoke-PlannerModel {
    param(
        [string]$PlannerEndpoint,
        [string]$PlannerModel,
        [hashtable]$PlannerInput
    )

    # 1. SYSTEM PROMPT
    # We will try a "Schema Only" approach to stop it from copying specific examples
    $systemPrompt = @"
You are a Logic Engine. You are NOT an assistant.
Your job is to read the INPUT DATA and output a JSON Plan to achieve the specified 'goal'.

RULES:
1. Use the 'tools' listed in the input.
2. If 'last_step' has data (like a list of notes), you MUST extract the REAL ID from it.
3. NEVER use placeholders like "INSERT_ID". Use the actual strings found in the data.
4. Output PURE JSON only. No markdown, no talking.
5. ONLY use tools from the tool manifest.

RESPONSE FORMAT STRUCTURE:
{
  "plan": {
    "steps": [
      { "id": 1, "label": "Description", "action": "tool_call", "tool": "tool.name", "params": { "param": "value" } }
    ]
  },
  "next_step_index": 0
}
"@

    # 2. USER PROMPT
    $inputJson = $PlannerInput | ConvertTo-Json -Depth 10
    $userContent = @"
*** INPUT DATA START ***
TOOL MANIFEST:
$inputJson
*** INPUT DATA END ***

INSTRUCTIONS:
Analyze the 'goal' and 'last_step' above.
Generate the next steps in the plan using the available tools.
Return the JSON object now:
"@

    # --- DEBUG LOGGING START ---
    # Save the FULL prompt context to a file so we can debug the LLM's view
    $fullDebugPrompt = "========== SYSTEM PROMPT ==========`n$systemPrompt`n`n========== USER PROMPT ==========`n$userContent"
    $promptFile = Join-Path $env:ECHO_ROOT "state\thinking\last_planner_prompt.txt"
    Set-Content -Path $promptFile -Value $fullDebugPrompt -Force
    # --- DEBUG LOGGING END ---

    $stopTokens = @('<|im_end|>', '<|eot_id|>', '```', 'assistant')

    $bodyObj = @{
        model       = $PlannerModel
        messages    = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user";   content = $userContent }
        )
        temperature = 0.1
        max_tokens  = 1024
        stop        = $stopTokens
    }
    
    $body = $bodyObj | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri $PlannerEndpoint -Method Post -Body $body -ContentType "application/json"
    } catch {
        throw "Planner API Call Failed: $($_.Exception.Message)"
    }

    if (-not $response.choices) {
        throw "Planner returned no choices. Raw response: $($response | ConvertTo-Json -Depth 2)"
    }

    $rawContent = $response.choices[0].message.content

    # Debug log response
    $debugFile = Join-Path $env:ECHO_ROOT "state\thinking\last_planner_raw.txt"
    Set-Content -Path $debugFile -Value $rawContent -Force

    # Clean up
    $rawContent = $rawContent -replace '```json', '' -replace '```', ''
    
    $startIndex = $rawContent.IndexOf('{')
    $endIndex   = $rawContent.LastIndexOf('}')
    if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        $rawContent = $rawContent.Substring($startIndex, ($endIndex - $startIndex + 1))
    }

    try {
        return $rawContent | ConvertFrom-Json
    }
    catch {
        throw "Planner returned invalid JSON. Raw content saved to $debugFile"
    }
}

# -------- Helper: state file path --------------------------------------------
function Get-PlanStatePath {
    param(
        [string]$StateRoot,
        [string]$LoopId
    )

    return (Join-Path $StateRoot "$LoopId.plan.json")
}

# -------- Thinking logs & summary paths --------------------------------------
$script:ThinkingLogRoot = "$env:ECHO_ROOT\logs"
$script:ThinkingLogFile = Join-Path $script:ThinkingLogRoot "thinking.log.jsonl"

if (-not (Test-Path $script:ThinkingLogRoot)) {
    New-Item -ItemType Directory -Force -Path $script:ThinkingLogRoot | Out-Null
}

if (-not (Get-Command Write-JsonlLine -ErrorAction SilentlyContinue)) {
    function Write-JsonlLine {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][hashtable]$Object
        )

        $line = $Object | ConvertTo-Json -Depth 10 -Compress
        if (-not (Test-Path $Path)) {
            New-Item -ItemType File -Force -Path $Path | Out-Null
        }
        Add-Content -Path $Path -Value $line
    }
}

function Write-ThinkingTrace {
    param(
        [Parameter(Mandatory = $true)][string]$LoopId,
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Payload
    )

    $obj = @{
        ts      = (Get-Date).ToString("o")
        loop_id = $LoopId
        event   = $Event
        data    = $Payload
    }

    Write-JsonlLine -Path $script:ThinkingLogFile -Object $obj
}

# -------- Helper: fix planner step shapes ------------------------------------
function Fix-PlanStepsShape {
    param(
        [object[]]$Steps
    )

    $fixed = @()
    foreach ($raw in $Steps) {
        $step = [pscustomobject]$raw

        # Force valid action
        if ($step.action -ne "tool_call" -and $step.action -ne "analysis") {
            if ($step.tool) {
                $step | Add-Member -NotePropertyName action -NotePropertyValue "tool_call" -Force
            } else {
                $step | Add-Member -NotePropertyName action -NotePropertyValue "analysis" -Force
            }
        }

        $fixed += $step
    }
    return $fixed
}

# -------- Helper: invoke one plan tool step via skills bus -------------------
function Invoke-PlanToolStep {
    param(
        [pscustomobject]$Step,
        [pscustomobject]$PlanState
    )

    # --- FIX 1: Allow "analysis" steps to pass naturally ---
    if ($Step.action -eq "analysis") {
        return @{
            success = $true
            error   = $null
            data    = @{
                step_id = $Step.id
                note    = "Analysis/Thought step processed successfully."
            }
        }
    }

    if ($Step.action -ne "tool_call") {
        return @{
            success = $false
            error   = "Step.action '$($Step.action)' is not 'tool_call'; no skill executed."
            data    = @{
                step_id = $Step.id
                note    = "Non-tool step; planner should handle this differently."
            }
        }
    }

    if (-not $Step.tool) {
        return @{
            success = $false
            error   = "tool_call step is missing 'tool' name."
            data    = @{
                step_id = $Step.id
            }
        }
    }

    # PHASE 1: EXECUTION
    $requestId = Send-SkillRequest -Step $Step -PlanState $PlanState
    $rawResult = Wait-SkillResponse -RequestId $requestId -TimeoutSeconds 15

    # PHASE 2: EVALUATION (normalize per tool)
    $normalized = Normalize-ToolResult -Tool $Step.tool -Result $rawResult

    return $normalized
}
# -------- Helper: per-loop summary for main brain ----------------------------
function Write-ThinkingSummary {
    param(
        [pscustomobject]$State,
        [string]$StateRoot
    )

    $loopId      = $State.loop_id
    $statePath   = Get-PlanStatePath -StateRoot $StateRoot -LoopId $loopId
    $summaryPath = Join-Path $StateRoot "$loopId.summary.json"

    $steps   = @($State.steps)
    $history = @($State.history)

    $executed = $history | Where-Object { $_.event -eq "step_executed" }

    $firstError = $null
    foreach ($h in $executed) {
        if ($h.result -and $h.result.error) {
            $firstError = @{
                step_id = $h.step_id
                error   = $h.result.error
            }
            break
        }
    }

    $lastEvent = $history[-1]

    $summary = [pscustomobject]@{
        loop_id        = $loopId
        goal           = $State.goal
        status         = $State.status
        total_steps    = $steps.Count
        executed_steps = $executed.Count
        last_step_id   = if ($executed.Count -gt 0) { $executed[-1].step_id } else { $null }
        first_error    = $firstError
        completed_all  = ($State.status -eq "done" -and $executed.Count -eq $steps.Count)
        finished_at    = if ($lastEvent) { $lastEvent.timestamp } else { (Get-Date).ToString("o") }
        history_digest = $history | ForEach-Object {
            [pscustomobject]@{
                step_id   = $_.step_id
                event     = $_.event
                summary   = $_.summary
                timestamp = $_.timestamp
            }
        }
        state_file     = $statePath
    }

    $summary | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $summaryPath

    Write-ThinkingTrace -LoopId $loopId -Event "loop_summary_written" -Payload @{
        summary_path = $summaryPath
        status       = $State.status
    }
}

# -------- Helper: create new LoopId ------------------------------------------
function New-LoopId {
    $ts = (Get-Date).ToString("yyyyMMddTHHmmss")
    $rand = -join ((65..90) + (48..57) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
    return "$ts-THINK-$rand"
}

# -------- Command: New-ThinkingPlan (Loop 0) ---------------------------------
function New-ThinkingPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Goal,
        [Parameter(Mandatory = $true)][string]$ContextSummary,
        [string]$StateRoot,
        [string]$ToolsFile,
        [string]$PlannerEndpoint,
        [string]$PlannerModel
    )

    $LoopId  = New-LoopId
    $tools   = Get-PlannerTools -Path $ToolsFile
    $lessons = Get-LessonsForPlanner -LessonsFile $LessonsFile

    $plannerInput = @{
        mode            = "initial"
        goal            = $Goal
        tools           = $tools
        previous_plan   = $null
        last_step       = $null
        context_summary = $ContextSummary
        lessons         = $lessons
    }

    $plannerOutput = Invoke-PlannerModel -PlannerEndpoint $PlannerEndpoint `
                                         -PlannerModel    $PlannerModel `
                                         -PlannerInput    $plannerInput

    # --- DEBUG: Catch malformed plans and save them to a file ---
    if (-not $plannerOutput.plan -or -not $plannerOutput.plan.steps) {
        $debugPath = Join-Path $StateRoot "planner_last_error.json"
        $plannerOutput | ConvertTo-Json -Depth 10 | Set-Content -Path $debugPath -Force
        throw "Planner did not return a valid plan. Saved output to: $debugPath"
    }
    # -----------------------------------------------------------

    if (-not $plannerOutput.plan -or -not $plannerOutput.plan.steps) {
        throw "Planner did not return a valid plan."
    }

    $fixedSteps = Fix-PlanStepsShape -Steps $plannerOutput.plan.steps

    $state = [pscustomobject]@{
        loop_id            = $LoopId
        goal               = $Goal
        status             = "running"   # running | done | error
        current_step_index = 0
        steps              = $fixedSteps
        history            = @(
            [pscustomobject]@{
                step_id   = 0
                event     = "plan_created"
                summary   = "Initial plan created by planner."
                timestamp = (Get-Date).ToString("o")
            }
        )
    }

    $statePath = Get-PlanStatePath -StateRoot $StateRoot -LoopId $LoopId
    $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath

    Write-ThinkingTrace -LoopId $LoopId -Event "plan_created" -Payload @{
        goal        = $Goal
        steps_count = (@($state.steps)).Count
    }

    $output = @{
        loop_id = $LoopId
        status  = "running"
        state   = $state
        message = "Thinking plan created."
    }

    $output | ConvertTo-Json -Depth 10
}

# -------- Command: Invoke-ThinkingTick (ONE step: execute → evaluate → replan)
function Invoke-ThinkingTick {
    param(
        [Parameter(Mandatory = $true)][string]$LoopId,
        [Parameter(Mandatory = $true)][string]$ContextSummary,
        [string]$StateRoot,
        [string]$ToolsFile,
        [string]$PlannerEndpoint,
        [string]$PlannerModel
    )

    $statePath = Get-PlanStatePath -StateRoot $StateRoot -LoopId $LoopId
    if (-not (Test-Path $statePath)) {
        throw "Plan state file not found for LoopId $LoopId at $statePath"
    }

    $stateJson = Get-Content -Raw -Path $statePath
    $state     = $stateJson | ConvertFrom-Json

    if ($state.status -ne "running") {
        $output = @{
            loop_id = $LoopId
            status  = $state.status
            message = "Plan is not running."
        }
        return ($output | ConvertTo-Json -Depth 10)
    }

    $steps = @($state.steps)
    $idx   = [int]$state.current_step_index

    if ($idx -ge $steps.Count) {
        $state.status = "done"
        $state.history += [pscustomobject]@{
            step_id   = -1
            event     = "plan_completed"
            summary   = "No more steps to execute."
            timestamp = (Get-Date).ToString("o")
        }

        $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath

        Write-ThinkingSummary -State $state -StateRoot $StateRoot

        Write-ThinkingTrace -LoopId $LoopId -Event "plan_completed" -Payload @{
            reason = "no_more_steps"
        }

        $output = @{
            loop_id = $LoopId
            status  = "done"
            message = "All steps completed."
        }
        return ($output | ConvertTo-Json -Depth 10)
    }

    $step = [pscustomobject]$steps[$idx]

    # ===== PHASE 1: EXECUTION via skills bus =================================
    $result = Invoke-PlanToolStep -Step $step -PlanState $state

    $state.history += [pscustomobject]@{
        step_id   = $step.id
        event     = "step_executed"
        summary   = "Step executed with result.success = $($result.success)"
        result    = $result
        timestamp = (Get-Date).ToString("o")
    }

    Write-ThinkingTrace -LoopId $LoopId -Event "step_executed" -Payload @{
        step_id = $step.id
        label   = $step.label
        tool    = $step.tool
        action  = $step.action
        success = $result.success
        error   = $result.error
    }

    # ===== PHASE 2: EVALUATION ===============================================
    $evalMessage = if ($result.success) {
        "Tool '$($step.tool)' succeeded."
    } else {
        if ($result.error) {
            "Tool '$($step.tool)' failed: $($result.error)"
        } else {
            "Tool '$($step.tool)' failed with no error message."
        }
    }

    $state.history += [pscustomobject]@{
        step_id   = $step.id
        event     = "step_evaluated"
        summary   = $evalMessage
        evaluation = @{
            success = $result.success
            error   = $result.error
        }
        timestamp = (Get-Date).ToString("o")
    }

    Write-ThinkingTrace -LoopId $LoopId -Event "step_evaluated" -Payload @{
        step_id = $step.id
        success = $result.success
        error   = $result.error
    }

    # ===== PHASE 3: REPLAN based on result ===================================
    $tools   = Get-PlannerTools -Path $ToolsFile
    $lessons = Get-LessonsForPlanner -LessonsFile $LessonsFile

    $previousPlan = @{
        steps = $state.steps
    }

    $plannerInput = @{
        mode            = "replan"
        goal            = $state.goal
        tools           = $tools
        previous_plan   = $previousPlan
        last_step       = @{
            index  = $idx
            step   = $step
            result = $result
        }
        context_summary = $ContextSummary
        lessons         = $lessons
    }

    $plannerOutput = Invoke-PlannerModel -PlannerEndpoint $PlannerEndpoint `
                                         -PlannerModel    $PlannerModel `
                                         -PlannerInput    $plannerInput

    $locked  = [int]($plannerOutput.locked_steps_up_to)
    $newPlan = $plannerOutput.plan
    $newStepsRaw = @($newPlan.steps)
    $newSteps = Fix-PlanStepsShape -Steps $newStepsRaw

    if ($locked -lt 0) { $locked = 0 }

    $oldSteps = @($state.steps)
    if ($locked -gt $oldSteps.Count) { $locked = $oldSteps.Count }

    if ($locked -eq 0) {
        $state.steps = $newSteps
    }
    else {
        $prefix = $oldSteps[0..($locked - 1)]
        $suffix = @()
        if ($locked -lt $newSteps.Count) {
            $suffix = $newSteps[$locked..($newSteps.Count - 1)]
        }
        $state.steps = @($prefix + $suffix)
    }

    # 1. Default: Move forward by 1
    $suggestedIndex = $idx + 1

    # 2. If Planner wants to jump, let it, BUT...
    if ($plannerOutput.PSObject.Properties.Name -contains "next_step_index") {
        $plannerIndex = [int]$plannerOutput.next_step_index
        
        # 3. ANTI-LOOP RULE: If the last step SUCCEEDED, do not allow going backward to the same step.
        if ($result.success -and $plannerIndex -le $idx) {
            Write-Host "[ThinkingLoop] Planner tried to loop back to $plannerIndex after success. Forcing forward to $suggestedIndex." -ForegroundColor Yellow
            $state.current_step_index = $suggestedIndex
        } 
        else {
            $state.current_step_index = $plannerIndex
        }
    }
    else {
        $state.current_step_index = $suggestedIndex
    }

    $stepCount = (@($state.steps)).Count
    
    # 4. FIX: If we ran off the end of the plan, mark done immediately
    if ($state.current_step_index -ge $stepCount) {
        $state.status = "done"
        $state.history += [pscustomobject]@{
            step_id   = -1
            event     = "plan_completed"
            summary   = "Plan completed (index advanced past last step)."
            timestamp = (Get-Date).ToString("o")
        }
        Write-ThinkingSummary -State $state -StateRoot $StateRoot
        Write-ThinkingTrace -LoopId $LoopId -Event "plan_completed" -Payload @{ reason = "index_advanced_past_end" }
        
        $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath
        
        return (@{
            loop_id = $LoopId
            status  = "done"
            message = "All steps completed."
        } | ConvertTo-Json -Depth 10)
    }

    $state.history += [pscustomobject]@{
        step_id   = $step.id
        event     = "plan_replanned"
        summary   = "Planner replanned; next_step_index=$($state.current_step_index)"
        timestamp = (Get-Date).ToString("o")
    }

    Write-ThinkingTrace -LoopId $LoopId -Event "plan_replanned" -Payload @{
        step_id         = $step.id
        next_step_index = $state.current_step_index
    }

    $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath

    $output = @{
        loop_id            = $LoopId
        status             = $state.status
        current_step_index = $state.current_step_index
        last_step          = $step
        last_result        = $result
        notes              = $plannerOutput.notes
    }

    $output | ConvertTo-Json -Depth 10
}

# -------- Script entrypoint --------------------------------------------------
if ($Mode -eq "Initial") {
    New-ThinkingPlan -Goal $Goal `
                     -ContextSummary $ContextSummary `
                     -StateRoot $StateRoot `
                     -ToolsFile $ToolsFile `
                     -PlannerEndpoint $PlannerEndpoint `
                     -PlannerModel $PlannerModel
}
elseif ($Mode -eq "Tick") {
    Invoke-ThinkingTick -LoopId $LoopId `
                        -ContextSummary $ContextSummary `
                        -StateRoot $StateRoot `
                        -ToolsFile $ToolsFile `
                        -PlannerEndpoint $PlannerEndpoint `
                        -PlannerModel $PlannerModel
}
else {
    # dot-sourced: just expose functions
}
