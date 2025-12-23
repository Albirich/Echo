param([string]$ConfigPath)

# --- CONFIG ---
$VisionUrl = "http://localhost:8081/v1/chat/completions" # Small Brain (Logic)
$GameStateFile = "D:\Echo\ui\game_state.json"

Write-Host "MTG Vision Core Online. Connecting to Neural Net..." -ForegroundColor Cyan

# --- HELPER: GET AI OPINION ---
function Analyze-Turn {
    param($BoardDescription)
    
    # We ask the logic brain to generate the "Director's Note" for the Main Brain
    $system = @"
You are the Magic: The Gathering Logic Engine.
1. Analyze the board state.
2. Decide the move.
3. Write a 'Context Prompt' for the Chat AI (Echo).
   - Tell Echo what just happened.
   - Tell Echo how to react (e.g., "Be cocky," "Panic," "Laugh at them").
   - KEEP IT SHORT.

OUTPUT JSON:
{
  "move": "Attack with everything",
  "echo_context": "[GAME STATE]: We are winning (20 vs 5 life). I just attacked with a 5/5 Dragon. \n[INSTRUCTION]: Gloat about our dragon. Call the opponent 'helpless'."
}
"@
    
    $payload = @{
        model = "small"
        messages = @(
            @{ role = "system"; content = $system },
            @{ role = "user"; content = "Board: $BoardDescription" }
        )
        temperature = 0.4
        response_format = @{ type = "json_object" }
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Uri $VisionUrl -Method Post -Body $payload -ContentType "application/json"
        return $response.choices[0].message.content | ConvertFrom-Json
    } catch { return $null }
}

# --- MAIN LOOP ---
while ($true) {
    # 1. [VISION WOULD GO HERE] - Simulating Board State for now
    $hp = Get-Random -Min 1 -Max 20
    $simBoard = "My HP: $hp. Opponent HP: 12. I have a 5/5 Flyer. They have no flyers."

    # 2. Ask Small Brain what to do
    $strategy = Analyze-Turn -BoardDescription $simBoard

    if ($strategy) {
        Write-Host "Move: $($strategy.move)" -ForegroundColor Green

        # 3. WRITE THE PROMPT FOR MAIN BRAIN
        # We save the exact text Echo needs to see into a shared file
        $export = @{
            game_active = $true
            text = $strategy.echo_context
            last_update = (Get-Date).ToString('HH:mm:ss')
        }
        $export | ConvertTo-Json | Set-Content $GameStateFile
    }

    # Wait for next turn (poll slower to save GPU)
    Start-Sleep -Seconds 5
}