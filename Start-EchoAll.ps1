param(
  [switch]$SkipVision,
  [switch]$SkipRoom
)

$ErrorActionPreference = 'Stop'

# -------------------------------
# Helpers
# -------------------------------
function Log { param([string]$Message) Write-Host "[EchoAll] $Message" -ForegroundColor Cyan }
function Warn { param([string]$Message) Write-Warning "[EchoAll][WARN] $Message" }

function Start-LlamaInstance {
  param(
    [string]$Name,
    [string]$ModelPath,
    [int]   $Port,
    [string]$Alias,
    [string]$PidFile,
    [string]$ChatTemplate = 'chatml',
    [string]$StdOutLog,
    [string]$StdErrLog
  )

  if (-not (Test-Path -LiteralPath $ModelPath)) { throw "Model for '$Name' not found: $ModelPath" }
  
  $exe = 'D:\llama-cpp\llama-server.exe'
  if ($env:LLAMA_SERVER_EXE) { $exe = $env:LLAMA_SERVER_EXE }

  # --- CHANGE: Added '-mg', '0' to force GPU 0 ---
  $args = @('-m', "`"$ModelPath`"", '--port', $Port, '--alias', $Alias, '--host', '127.0.0.1', '--chat-template', $ChatTemplate, '--embedding', '--n-gpu-layers','999', '-t', '2', '-c', '4096', '-mg', '0')

  Log "Starting $Name on Port $Port ($Alias)..."
  $psi = @{ FilePath = $exe; ArgumentList = $args; WindowStyle = 'Hidden'; RedirectStandardOutput = $StdOutLog; RedirectStandardError = $StdErrLog }
  $proc = Start-Process @psi -PassThru
  [IO.File]::WriteAllText($PidFile, "$($proc.Id)")
  
  # Wait for ready
  $url = "http://127.0.0.1:$Port/health"
  for ($i=0; $i -lt 30; $i++) {
      try { if ((Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 1).StatusCode -eq 500) { Log "$Name is Ready."; return } } catch {}
      Start-Sleep -Seconds 1
  }
  Warn "$Name failed to respond on port $Port."
}

function Start-Child {
  param([string]$Name, [string]$File, [string]$PidFile, [switch]$Hidden)
  if (-not (Test-Path $File)) { Warn "$Name script missing: $File"; return }
  $style = if ($Hidden) { 'Hidden' } else { 'Normal' }
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoLogo -File `"$File`"" -WindowStyle $style -PassThru
  [IO.File]::WriteAllText($PidFile, "$($proc.Id)")
  Log "Started $Name (PID $($proc.Id))"
}

# -------------------------------
# Configuration
# -------------------------------
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Logs = Join-Path $Root 'logs\llama'; New-Item -Force -ItemType Directory -Path $Logs | Out-Null
$State = Join-Path $Root 'state'; New-Item -Force -ItemType Directory -Path $State | Out-Null

$env:ECHO_ROOT = $Root
$env:ECHO_HOME = $Root

# --- MODEL PATHS ---
$PathMain  = Join-Path $Root 'models\Llama-3.1-128k-Dark-Planet-Uncensored-8B-Q6_k.gguf'
$PathSmall = Join-Path $Root 'models\nidum-llama-3.2-3b-uncensored-q4_k_m.gguf'

# --- SERVERS ---
$env:ECHO_MAIN_SERVER  = 'http://127.0.0.1:8080'
$env:ECHO_SMALL_SERVER = 'http://127.0.0.1:8081'

# -------------------------------
# Start Servers
# -------------------------------
Start-LlamaInstance -Name 'Main'  -ModelPath $PathMain  -Port 8080 -Alias 'main'  -PidFile "$State\llama-main.pid"  -StdOutLog "$Logs\main.out"  -StdErrLog "$Logs\main.err"
Start-LlamaInstance -Name 'Small' -ModelPath $PathSmall -Port 8081 -Alias 'small' -PidFile "$State\llama-small.pid" -StdOutLog "$Logs\small.out" -StdErrLog "$Logs\small.err"

# -------------------------------
# Start Components
# -------------------------------
if (-not $SkipVision) { Start-Child -Name 'VisionServer' -File "$Root\Start-VisionServer.ps1" -PidFile "$State\vision_server.pid" -Hidden }
Start-Child -Name 'Whisper'      -File "$Root\tools\Start-WhisperStreamToInbox.ps1" -PidFile "$State\whisper.pid" -Hidden
if (-not $SkipRoom) { Start-Child -Name 'Room' -File "$Root\Start-EchoRoom.ps1" -PidFile "$State\room.pid" }

# Start Skills
Start-Child -Name 'SkillsLoop'   -File "$Root\scripts\SkillsLoop.ps1"   -PidFile "$State\skillsloop.pid"   -Hidden
Start-Child -Name 'SkillRuntime' -File "$Root\scripts\SkillRuntime.ps1" -PidFile "$State\skillruntime.pid" -Hidden

# Start Brains
Start-Child -Name 'Echo' -File "$Root\Start-Echo.ps1" -PidFile "$State\echo.pid" -Hidden
Start-Child -Name 'IM'   -File "$Root\Start-IM.ps1"   -PidFile "$State\im.pid"   -Hidden

Log "Echo stack is fully live with 2 Brain Lanes."