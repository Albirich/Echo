# Start-GameManager.ps1
# Watches state.json for 'gamePromptFile' changes.
# Swaps between "Peace Mode" (Standard Vision) and "Game Mode" (Game Scripts).

$StatePath = "D:\Echo\ui\state.json"
$GamePromptsDir = "D:\Echo\config\game-prompts"
$CurrentGame = $null
$GameProcess = $null

Write-Host "Game Manager Online. Waiting for orders..." -ForegroundColor Cyan

while ($true) {
    try {
        # 1. Read State (with retry for file locking)
        $state = Get-Content $StatePath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        
        if ($state) {
            $selectedGame = $state.gamePromptFile # e.g., "mtg.json" or ""

            # 2. Check for Change
            if ($selectedGame -ne $CurrentGame) {
                Write-Host "Game Switch Detected: '$CurrentGame' -> '$selectedGame'" -ForegroundColor Yellow
                
                # --- TEARDOWN PHASE ---
                if ($GameProcess) { 
                    Write-Host "Stopping previous game script..."
                    Stop-Process -Id $GameProcess.Id -Force -ErrorAction SilentlyContinue 
                    $GameProcess = $null
                }

                # Restart Standard Vision if we went back to "None"
                if ([string]::IsNullOrWhiteSpace($selectedGame)) {
                    Write-Host "Returning to Standard Mode." -ForegroundColor Green
                    # Check if standard vision is running, if not, start it
                    if (-not (Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object {$_.MainWindowTitle -like "*VisionProbe-Lite*" })) {
                        Start-Process powershell -ArgumentList "-File D:\Echo\Start-VisionProbe-Lite.ps1" -WindowStyle Hidden
                    }
                } 
                
                # --- STARTUP PHASE ---
                else {
                    $configPath = Join-Path $GamePromptsDir $selectedGame
                    if (Test-Path $configPath) {
                        $config = Get-Content $configPath -Raw | ConvertFrom-Json
                        
                        # A. Kill Standard Vision (Free up the 580)
                        $visionProc = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -like "*Start-VisionProbe-Lite.ps1*" }
                        if ($visionProc) { Stop-Process -Id $visionProc.ProcessId -Force }
                        
                        # B. Launch The Specific Game Script
                        $scriptName = $config.script
                        $scriptPath = "D:\Echo\games\$scriptName"
                        
                        if (Test-Path $scriptPath) {
                            Write-Host "Launching Game Core: $scriptName" -ForegroundColor Magenta
                            # Pass the config path so the script knows its prompts
                            $GameProcess = Start-Process powershell -ArgumentList "-File `"$scriptPath`" -ConfigPath `"$configPath`"" -PassThru
                        } else {
                            Write-Warning "Script not found: $scriptPath"
                        }
                    }
                }
                
                $CurrentGame = $selectedGame
            }
        }
    } catch {
        # Ignore JSON read errors during write
    }
    Start-Sleep -Seconds 2
}