$prompt_file = "d:\Echo\state\thinking\last_planner_prompt.txt"
$prompt_text = Get-Content -Raw -Path $prompt_file

# Extract the user prompt
$user_prompt_start = $prompt_text.IndexOf("*** INPUT DATA START ***")
$user_prompt_end = $prompt_text.IndexOf("*** INPUT DATA END ***")
$user_prompt = $prompt_text.Substring($user_prompt_start, $user_prompt_end - $user_prompt_start + "*** INPUT DATA END ***".Length)

$messages = @(
    @{
        "role" = "system"
        "content" = "You are a Logic Engine. You are NOT an assistant.
Your job is to read the INPUT DATA and output a JSON Plan to achieve the specified 'goal'.

RULES:
1. Use the 'tools' listed in the input.
2. If 'last_step' has data (like a list of notes), you MUST extract the REAL ID from it.
3. NEVER use placeholders like "INSERT_ID". Use the actual strings found in the data.
4. Output PURE JSON only. No markdown, no talking.

RESPONSE FORMAT:
{
  "plan": {
    "steps": [
      { "id": 1, "label": "List notes", "action": "tool_call", "tool": "room.list_notes", "params": {} }
    ]
  },
  "next_step_index": 0
}"
    },
    @{
        "role" = "user"
        "content" = $user_prompt
    }
)

$body = @{
    "model" = "planner-small"
    "messages" = $messages
    "temperature" = 0.1
    "max_tokens" = 1024
    "stop" = @("<|im_end|>", "<|eot_id|>", "```", "assistant")
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:8081/v1/chat/completions" -Method Post -Body $body -ContentType "application/json"
    Write-Host "Raw response:"
    Write-Host ($response | ConvertTo-Json -Depth 10)
} catch {
    Write-Host "Error sending request:"
    Write-Host $_.Exception.Message
}
