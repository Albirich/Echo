param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("None", "Initial", "Tick")]
    [string]$Mode = "None",

    [string]$Goal,
    [string]$ContextSummary,
    [string]$LoopId,

    [string]$StateRoot = "$env:ECHO_ROOT\state\thinking",
    [string]$ToolsFile = "$env:ECHO_ROOT\skills\manifest.json",
    
    # Default parameters (Start-Echo overrides these)
    [string]$PlannerEndpoint = "http://127.0.0.1:8080/v1/chat/completions",
    [string]$PlannerModel = "main",
    
    [string]$LessonsFile = "$env:ECHO_ROOT\memory\lessons.thinking.jsonl"
)

# -------- Side Channel Path --------------------------------------------------
$ThinkingInfoFile = Join-Path $env:ECHO_ROOT "state\ThinkingInfo.json"

# -------- Skill bus paths ----------------------------------------------------
$script:SkillOutbox = "$env:ECHO_ROOT\ui\skills.outbox.jsonl"
$script:SkillInbox  = "$env:ECHO_ROOT\ui\skills.inbox.jsonl"

if (-not (Test-Path (Split-Path $script:SkillOutbox))) { New-Item -ItemType Directory -Force -Path (Split-Path $script:SkillOutbox) | Out-Null }
if (-not (Test-Path (Split-Path $script:SkillInbox))) { New-Item -ItemType Directory -Force -Path (Split-Path $script:SkillInbox) | Out-Null }
if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null }

# -------- Helper: append one JSONL line safely -------------------------------
function Write-JsonlLine {
    param([string]$Path, [hashtable]$Object)
    $line = $Object | ConvertTo-Json -Depth 10 -Compress
    Add-Content -Path $Path -Value $line
}

function Get-LessonsForPlanner {
    param([string]$LessonsFile)
    if (-not (Test-Path $LessonsFile)) { return @() }
    $lines = Get-Content -Path $LessonsFile -ErrorAction SilentlyContinue
    $lessons = @()
    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        try { $lessons += $line | ConvertFrom-Json } catch {}
    }
    return $lessons
}

function Send-SkillRequest {
    param([pscustomobject]$Step, [pscustomobject]$PlanState)
    $requestId = [guid]::NewGuid().ToString()
    $payload = @{
        type = "skill_request"; request_id = $requestId; loop_id = $PlanState.loop_id
        goal = $PlanState.goal; step_id = $Step.id; step_label = $Step.label
        skill = $Step.tool; params = $Step.params; created_at = (Get-Date).ToString("o")
    }
    Write-JsonlLine -Path $script:SkillOutbox -Object $payload
    return $requestId
}

function Wait-SkillResponse {
    param([string]$RequestId, [int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $script:SkillInbox) {
            $lines = @(Get-Content -Path $script:SkillInbox -ErrorAction SilentlyContinue)
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                try {
                    $obj = $lines[$i] | ConvertFrom-Json
                    if ($obj.type -eq "skill_response" -and $obj.request_id -eq $RequestId) {
                        return @{ success = [bool]$obj.success; error = $obj.error; data = $obj.data }
                    }
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return @{ success = $false; error = "Timeout"; data = $null }
}

function Normalize-ToolResult {
    param([string]$Tool, [hashtable]$Result)
    return $Result
}

# --- THE MISSING FUNCTION ---
function Invoke-PlanToolStep {
    param(
        [pscustomobject]$Step,
        [pscustomobject]$PlanState
    )

    if ($Step.action -eq "analysis") {
        return @{
            success = $true
            error   = $null
            data    = @{ step_id = $Step.id; note = "Analysis step processed." }
        }
    }

    if ($Step.action -ne "tool_call") {
        return @{
            success = $false
            error   = "Step.action '$($Step.action)' is not 'tool_call'."
            data    = @{ step_id = $Step.id }
        }
    }

    if (-not $Step.tool) {
        return @{
            success = $false
            error   = "tool_call step is missing 'tool' name."
            data    = @{ step_id = $Step.id }
        }
    }

    # EXECUTE
    $requestId = Send-SkillRequest -Step $Step -PlanState $PlanState
    $rawResult = Wait-SkillResponse -RequestId $requestId -TimeoutSeconds 15

    # NORMALIZE
    return Normalize-ToolResult -Tool $Step.tool -Result $rawResult
}
# ----------------------------

function Get-PlannerTools {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Tools manifest not found: $Path" }
    $json = Get-Content -Raw -Path $Path | ConvertFrom-Json
    return $json.tools
}

function Invoke-PlannerModel {
    param([string]$PlannerEndpoint, [string]$PlannerModel, [hashtable]$PlannerInput)

    $systemPrompt = @"
You are a backend JSON generator. You are NOT a chat assistant.
You receive input data and return a JSON object.
You NEVER speak. You NEVER explain. You ONLY output JSON.

RULES:
1. Use the 'tools' listed in the input.
2. If 'last_step' contains a list, EXTRACT the ID from it for the next step.
3. NO PLACEHOLDERS. Use real data.
4. If 'DIRECT_TOOL_OUTPUT' is provided, prioritize that data.

RESPONSE FORMAT:
{
  "plan": {
    "steps": [
      { "id": 1, "label": "List items", "action": "tool_call", "tool": "room.list_notes", "params": {} },
      { "id": 2, "label": "Delete item", "action": "tool_call", "tool": "room.delete_note", "params": { "id": "REAL_ID_HERE" } }
    ]
  },
  "next_step_index": 0
}
"@

    # --- SIDE CHANNEL INJECTION ---
    $infoFile = Join-Path $env:ECHO_ROOT "state\ThinkingInfo.json"
    $extraInfo = ""
    if (Test-Path $infoFile) {
        $rawInfo = Get-Content -Raw -Path $infoFile
        $extraInfo = "`n*** DIRECT TOOL OUTPUT (ThinkingInfo) ***`n$rawInfo`n*******************************************`n"
    }

    $inputJson = $PlannerInput | ConvertTo-Json -Depth 10
    $userContent = @"
*** INPUT DATA START ***
$inputJson
*** INPUT DATA END ***

$extraInfo

INSTRUCTIONS:
1. Analyze the 'goal' and available data.
2. Generate the next steps in the plan.
3. OUTPUT RAW JSON ONLY. DO NOT write "Here is the plan".
4. START YOUR RESPONSE WITH '{'.

JSON:
"@

    # Debug Log
    $fullPromptLog = "========== SYSTEM ==========`n$systemPrompt`n`n========== USER ==========`n$userContent"
    $logPath = Join-Path $env:ECHO_ROOT "state\thinking\last_planner_prompt.txt"
    Set-Content -Path $logPath -Value $fullPromptLog -Force

    $stopTokens = @('<|im_end|>', '<|eot_id|>', '```', 'assistant')

    $bodyObj = @{
        model = $PlannerModel
        messages = @(
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

    if (-not $response.choices) { throw "Planner returned no choices." }

    $rawContent = $response.choices[0].message.content
    Set-Content -Path (Join-Path $env:ECHO_ROOT "state\thinking\last_planner_raw.txt") -Value $rawContent -Force

    $rawContent = $rawContent -replace '```json', '' -replace '```', ''
    $startIndex = $rawContent.IndexOf('{')
    $endIndex   = $rawContent.LastIndexOf('}')
    
    if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        $rawContent = $rawContent.Substring($startIndex, ($endIndex - $startIndex + 1))
    }

    try { return $rawContent | ConvertFrom-Json }
    catch { throw "Planner returned invalid JSON." }
}

function Get-PlanStatePath { param($StateRoot, $LoopId) return (Join-Path $StateRoot "$LoopId.plan.json") }
function Fix-PlanStepsShape { param($Steps) return $Steps } 

function New-ThinkingPlan {
    param($Goal, $ContextSummary, $StateRoot, $ToolsFile, $PlannerEndpoint, $PlannerModel)

    $LoopId  = (Get-Date).ToString("yyyyMMddTHHmmss") + "-THINK-" + (-join ((65..90) + (48..57) | Get-Random -Count 5 | ForEach-Object { [char]$_ }))
    $tools   = Get-PlannerTools -Path $ToolsFile
    $lessons = Get-LessonsForPlanner -LessonsFile $LessonsFile

    # --- FIX: DO NOT DELETE ThinkingInfo.json HERE ---
    # We want to keep it if it was just populated by SkillsLoop
    # $infoFile = Join-Path $env:ECHO_ROOT "state\ThinkingInfo.json"
    # if (Test-Path $infoFile) { Remove-Item $infoFile -Force }
    # -------------------------------------------------

    $plannerInput = @{
        mode = "initial"; goal = $Goal; tools = $tools
        previous_plan = $null; last_step = $null
        context_summary = $ContextSummary; lessons = $lessons
    }

    $plannerOutput = Invoke-PlannerModel -PlannerEndpoint $PlannerEndpoint -PlannerModel $PlannerModel -PlannerInput $plannerInput
    $fixedSteps = Fix-PlanStepsShape -Steps $plannerOutput.plan.steps

    $state = [pscustomobject]@{
        loop_id = $LoopId; goal = $Goal; status = "running"; current_step_index = 0
        steps = $fixedSteps; history = @()
    }
    
    $statePath = Get-PlanStatePath -StateRoot $StateRoot -LoopId $LoopId
    $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath

    return (@{ loop_id = $LoopId; status = "running" } | ConvertTo-Json -Depth 10)
}

function Invoke-ThinkingTick {
    param($LoopId, $ContextSummary, $StateRoot, $ToolsFile, $PlannerEndpoint, $PlannerModel)

    $statePath = Get-PlanStatePath -StateRoot $StateRoot -LoopId $LoopId
    $state = Get-Content -Raw -Path $statePath | ConvertFrom-Json
    $steps = @($state.steps)
    $idx   = [int]$state.current_step_index

    if ($idx -ge $steps.Count) {
        $state.status = "done"
        $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath
        
        # Cleanup handled in Start-Echo
        return (@{ loop_id = $LoopId; status = "done" } | ConvertTo-Json -Depth 10)
    }

    $step = $steps[$idx]
    
    # --- EXECUTE THE STEP ---
    $result = Invoke-PlanToolStep -Step $step -PlanState $state

    # Log history
    $state.history += [pscustomobject]@{
        step_id   = $step.id
        event     = "step_executed"
        summary   = "Step executed with result.success = $($result.success)"
        result    = $result
        timestamp = (Get-Date).ToString("o")
    }
    
    # --- FIX: SAVE IMMEDIATELY SO WE DON'T LOSE PROGRESS IF PLANNER CRASHES ---
    $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath
    # --------------------------------------------------------------------------

    # REPLANNING
    $tools   = Get-PlannerTools -Path $ToolsFile
    $plannerInput = @{
        mode = "replan"; goal = $state.goal; tools = $tools
        previous_plan = @{ steps = $state.steps }
        last_step = @{ index = $idx; step = $step; result = $result }
        context_summary = $ContextSummary
    }

    $plannerOutput = Invoke-PlannerModel -PlannerEndpoint $PlannerEndpoint -PlannerModel $PlannerModel -PlannerInput $plannerInput
    
    $state.steps = $plannerOutput.plan.steps
    $state.current_step_index = [int]$plannerOutput.next_step_index
    $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath
    
    return (@{ loop_id = $LoopId; status = "running" } | ConvertTo-Json -Depth 10)
}

if ($Mode -eq "Initial") {
    New-ThinkingPlan -Goal $Goal -ContextSummary $ContextSummary -StateRoot $StateRoot -ToolsFile $ToolsFile -PlannerEndpoint $PlannerEndpoint -PlannerModel $PlannerModel
}
elseif ($Mode -eq "Tick") {
    Invoke-ThinkingTick -LoopId $LoopId -ContextSummary $ContextSummary -StateRoot $StateRoot -ToolsFile $ToolsFile -PlannerEndpoint $PlannerEndpoint -PlannerModel $PlannerModel
}