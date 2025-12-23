# MTG PILOT v4 - MOUSE CONTROL EDITION
param([string]$ConfigPath)

# --- CONFIGURATION ---
$Config     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$VisionJson = "D:\Echo\state\mtg_vision.json"
$GameState  = "D:\Echo\ui\game_state.json"
$LogicUrl   = "http://localhost:8081/v1/chat/completions"
$PythonExe  = "python"

# --- 0. WINDOWS API (MOUSE & WINDOW TRACKING) ---
$Win32 = @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static string GetActiveWindowTitle() {
        const int nChars = 256;
        System.Text.StringBuilder Buff = new System.Text.StringBuilder(nChars);
        IntPtr handle = GetForegroundWindow();
        if (GetWindowText(handle, Buff, nChars) > 0) return Buff.ToString();
        return null;
    }

    public static void Click(int x, int y, bool doubleClick) {
        SetCursorPos(x, y);
        mouse_event(0x02, 0, 0, 0, 0); // Left Down
        mouse_event(0x04, 0, 0, 0, 0); // Left Up
        if (doubleClick) {
            System.Threading.Thread.Sleep(100);
            mouse_event(0x02, 0, 0, 0, 0);
            mouse_event(0x04, 0, 0, 0, 0);
        }
    }
}
"@
Add-Type -TypeDefinition $Win32

# --- 1. START VISION ---
Write-Host "Launching Vision System..." -ForegroundColor Cyan
$VisionScript = Join-Path "D:\Echo" $Config.vision_script
$VisionProcess = Start-Process -FilePath $PythonExe -ArgumentList "$VisionScript $Config.vision_args" -PassThru -WindowStyle Hidden

# --- 2. CLICK LOGIC ---
function Send-Click {
    param([double]$xPct, [double]$yPct, [switch]$Double)
    
    # Get active window handle
    $hWnd = [Win32]::GetForegroundWindow()
    $rect = New-Object Win32+RECT
    [void][Win32]::GetWindowRect($hWnd, [ref]$rect)
    
    $width  = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    
    # Calculate absolute pixels
    $clickX = $rect.Left + [int]($width * $xPct)
    $clickY = $rect.Top + [int]($height * $yPct)
    
    Write-Host "Clicking at $clickX, $clickY ($($xPct*100)%, $($yPct*100)%)" -ForegroundColor Green
    [Win32]::Click($clickX, $clickY, $Double)
}

function Execute-Command {
    param($Cmd)
    if (-not $Cmd) { return }
    
    # SAFETY: Only click if MTGA is active
    $title = [Win32]::GetActiveWindowTitle()
    if ($title -notmatch "MTGA") {
        Write-Warning "Skipping click: MTGA is not focused."
        return
    }

    switch ($Cmd) {
        "[PASS]"       { Send-Click -xPct 0.90 -yPct 0.90 } # Bottom Right corner
        "[RESOLVE]"    { Send-Click -xPct 0.90 -yPct 0.85 } # Slightly above pass
        "[KEEP]"       { Send-Click -xPct 0.55 -yPct 0.85 } # Keep Hand button
        "[ATTACK_ALL]" { Send-Click -xPct 0.90 -yPct 0.75 } # Often appears on right
        
        # HAND ZONES (Approximate)
        "[PLAY_1]"     { Send-Click -xPct 0.35 -yPct 0.95 -Double } # Left-ish
        "[PLAY_2]"     { Send-Click -xPct 0.40 -yPct 0.95 -Double }
        "[PLAY_3]"     { Send-Click -xPct 0.45 -yPct 0.95 -Double }
        "[PLAY_4]"     { Send-Click -xPct 0.50 -yPct 0.95 -Double } # Center
        "[PLAY_5]"     { Send-Click -xPct 0.55 -yPct 0.95 -Double }
        "[PLAY_6]"     { Send-Click -xPct 0.60 -yPct 0.95 -Double }
        
        Default        { Write-Warning "Unknown Command: $Cmd" }
    }
}

# --- 3. THE LOOP ---
try {
    Write-Host "MTG Mouse Pilot Online. Waiting for game state..." -ForegroundColor Cyan
    while ($true) {
        if (Test-Path $VisionJson) {
            $rawVision = $null
            for ($i=0; $i -lt 5; $i++) { try { $rawVision = Get-Content $VisionJson -Raw | ConvertFrom-Json; break } catch { Start-Sleep -Milliseconds 100 } }

            if ($rawVision) {
                $ocrLines = $rawVision.ocr_top -join ", "
                
                # Simple check to ensure we are actually seeing the game
                if ($ocrLines.Length -gt 5) {
                    
                    $payload = @{
                        model = "small"
                        messages = @(
                            @{ role = "system"; content = $Config.small_brain_prompt },
                            @{ role = "user"; content = "SCREEN TEXT: $ocrLines" }
                        )
                        temperature = 0.1
                        response_format = @{ type = "json_object" }
                    } | ConvertTo-Json -Depth 5

                    try {
                        $response = Invoke-RestMethod -Uri $LogicUrl -Method Post -Body $payload -ContentType "application/json"
                        $decision = $response.choices[0].message.content | ConvertFrom-Json

                        if ($decision.command) {
                            Execute-Command -Cmd $decision.command
                        }

                        if ($decision.summary) {
                            @{
                                game_active = $true
                                text = $decision.summary
                                timestamp = (Get-Date).ToString("HH:mm:ss")
                            } | ConvertTo-Json | Set-Content $GameState
                        }
                    } catch {}
                }
            }
        }
        Start-Sleep -Seconds 4 
    }
}
finally {
    if ($VisionProcess) { Stop-Process -Id $VisionProcess.Id -Force -ErrorAction SilentlyContinue }
}