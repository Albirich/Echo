param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("None", "Initial", "Tick")]
    [string]$Mode = "None",

    [string]$Goal,
    [string]$ContextSummary,
    [string]$LoopId,

    [string]$StateRoot = "$env:ECHO_ROOT\state\thinking",
    [string]$ToolsFile = "$env:ECHO_ROOT\skills\manifest.json",
    [string]$PlannerEndpoint = "http://127.0.0.1:8080/v1/chat/completions",
    [string]$PlannerModel = "main",
    [string]$LessonsFile = "$env:ECHO_ROOT\memory\lessons.thinking.jsonl"
)

# -------- Setup Paths --------------------------------------------------------
$ThinkingInfoFile = Join-Path $env:ECHO_ROOT "state\ThinkingInfo.json"
$script:SkillOutbox = "$env:ECHO_ROOT\ui\skills.outbox.jsonl"
$script:SkillInbox  = "$env:ECHO_ROOT\ui\skills.inbox.jsonl"

if (-not (Test-Path (Split-Path $script:SkillOutbox))) { New-Item -ItemType Directory -Force -Path (Split-Path $script:SkillOutbox) | Out-Null }
if (-not (Test-Path (Split-Path $script:SkillInbox))) { New-Item -ItemType Directory -Force -Path (Split-Path $script:SkillInbox) | Out-Null }
if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null }

# -------- Helpers ------------------------------------------------------------
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
        try { 
            $obj = $line | ConvertFrom-Json
            if ($obj.content) { $lessons += $obj }
        } catch {}
    }
    
    $unique = $lessons | Sort-Object -Property title -Unique
    $finalList = @(); $chars = 0
    foreach ($L in $unique) {
        $len = ($L | ConvertTo-Json -Compress).Length
        if (($chars + $len) -lt 1000) { $finalList += $L; $chars += $len } else { break }
    }
    return $finalList
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

function Invoke-PlanToolStep {
    param([pscustomobject]$Step, [pscustomobject]$PlanState)
    if ($Step.action -eq "analysis") { return @{ success=$true; data=@{ note="Analysis done." } } }
    if ($Step.action -ne "tool_call") { return @{ success=$false; error="Not a tool call" } }
    
    $requestId = Send-SkillRequest -Step $Step -PlanState $PlanState
    $rawResult = Wait-SkillResponse -RequestId $requestId -TimeoutSeconds 15
    return $rawResult
}

function Get-PlannerTools {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Tools manifest not found: $Path" }
    $json = Get-Content -Raw -Path $Path | ConvertFrom-Json
    return $json.tools
}

function Invoke-PlannerModel {
    param([string]$PlannerEndpoint, [string]$PlannerModel, [hashtable]$PlannerInput)

    $systemPrompt = @"
You are the inner cognitive engine of Echo.
You are planning actions to achieve a goal.
Be creative. If a tool fails, try a different approach.
You don't need to be perfect, you just need to try.

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
      { "id": 2, "label": "Delete item", "action": "tool_call", "tool": "room.delete_note", "params": { "id": "EXAMPLE_GUID" } }
    ]
  },
  "next_step_index": 0
}
"@

    # --- 1. SIDE CHANNEL INJECTION (Truncated) ---
    $infoFile = Join-Path $env:ECHO_ROOT "state\ThinkingInfo.json"
    $extraInfo = ""
    if (Test-Path $infoFile) {
        try {
            $rawContent = Get-Content -Raw -Path $infoFile
            $jsonObj = $rawContent | ConvertFrom-Json
            if ($jsonObj.data -is [System.Array] -and $jsonObj.data.Count -gt 15) {
                $truncatedData = $jsonObj.data | Select-Object -First 15
                $jsonObj.data = $truncatedData
                $rawInfo = ($jsonObj | ConvertTo-Json -Depth 5 -Compress) + " ... [TRUNCATED]"
            } else {
                $rawInfo = $jsonObj | ConvertTo-Json -Depth 5 -Compress
            }
            if ($rawInfo.Length -gt 2500) { $rawInfo = $rawInfo.Substring(0, 2500) + "... [HARD TRUNCATED]" }
            $extraInfo = "`n*** DIRECT TOOL OUTPUT (ThinkingInfo) ***`n$rawInfo`n*******************************************`n"
        } catch { }
    }

    # --- 2. INPUT SANITIZATION (CRITICAL FIX) ---
    # We must remove large data blobs from 'last_step' before serialization to avoid 400 Bad Request
    if ($PlannerInput.last_step -and $PlannerInput.last_step.result -and $PlannerInput.last_step.result.data) {
        # Check if data is an array or string that is too big
        $d = $PlannerInput.last_step.result.data
        if ($d -is [System.Array] -and $d.Count -gt 5) {
             $PlannerInput.last_step.result.data = "Data too large to display directly ($($d.Count) items). See DIRECT TOOL OUTPUT below."
        }
    }
    # --------------------------------------------

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

    $stopTokens = @('<|im_end|>', '<|eot_id|>', '```', 'assistant')
    $bodyObj = @{
        model = $PlannerModel
        messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user";   content = $userContent }
        )
        temperature = 0.1
        max_tokens  = 2048
        stop        = $stopTokens
    }
    
    $body = $bodyObj | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri $PlannerEndpoint -Method Post -Body $body -ContentType "application/json"
    } catch {
        throw "Planner API Failed: $($_.Exception.Message)"
    }

    if (-not $response.choices) { throw "Planner returned no choices." }

    $rawContent = $response.choices[0].message.content
    $rawContent = $rawContent -replace '```json', '' -replace '```', ''
    $startIndex = $rawContent.IndexOf('{')
    $endIndex   = $rawContent.LastIndexOf('}')
    
    if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        $rawContent = $rawContent.Substring($startIndex, ($endIndex - $startIndex + 1))
    }

    try { return $rawContent | ConvertFrom-Json }
    catch { throw "Planner returned invalid JSON." }
}function Get-PlanStatePath { param($StateRoot, $LoopId) return (Join-Path $StateRoot "$LoopId.plan.json") }
function Fix-PlanStepsShape { param($Steps) return $Steps } 

function New-ThinkingPlan {
    param($Goal, $ContextSummary, $StateRoot, $ToolsFile, $PlannerEndpoint, $PlannerModel)

    $LoopId  = (Get-Date).ToString("yyyyMMddTHHmmss") + "-THINK-" + (-join ((65..90) + (48..57) | Get-Random -Count 5 | ForEach-Object { [char]$_ }))
    $tools   = Get-PlannerTools -Path $ToolsFile
    $lessons = Get-LessonsForPlanner -LessonsFile $LessonsFile

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

    # --- SAFETY BRAKE: STOP IF HISTORY TOO LONG ---
    if ($state.history.Count -ge 10) {
        $state.status = "done"
        $state.history += [pscustomobject]@{
            step_id = -1; event = "forced_stop"; summary = "Terminated after 10 steps to prevent infinite loop."
        }
        $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath
        return (@{ loop_id = $LoopId; status = "done"; history = $state.history } | ConvertTo-Json -Depth 10)
    }

    if ($idx -ge $steps.Count) {
        $state.status = "done"
        $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath
        return (@{ loop_id = $LoopId; status = "done"; history = $state.history } | ConvertTo-Json -Depth 10)
    }

    $step = $steps[$idx]
    $result = Invoke-PlanToolStep -Step $step -PlanState $state

    # Log history
    $state.history += [pscustomobject]@{
        step_id   = $step.id
        event     = "step_executed"
        summary   = "Step executed with result.success = $($result.success)"
        result    = $result
        timestamp = (Get-Date).ToString("o")
    }
    
    # Save result immediately
    $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath

    # --- CRITICAL FIX: STOP IF CREATION SUCCEEDED ---
    # If we just successfully added a note, declare victory and STOP.
    # This prevents the AI from hallucinating "cleanup" tasks or adding duplicate notes.
    if ($step.tool -eq "room.add_note" -and $result.success) {
        $state.status = "done"
        $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $statePath
        return (@{ loop_id = $LoopId; status = "done"; history = $state.history } | ConvertTo-Json -Depth 10)
    }
    # ------------------------------------------------

    # REPLANNING (Only if we haven't stopped)
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