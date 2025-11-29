param(
  [switch]$SkipVision,
  [switch]$SkipRoom
)

$ErrorActionPreference = 'Stop'

# -------------------------------
# Helpers
# -------------------------------
function Log {
  param([string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[EchoAll] $Message"
}

function Warn {
  param([string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Warning "[EchoAll][WARN] $Message"
}

function Start-Child {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$File,
    [string]$Arguments,
    [string]$PidFile,
    [switch]$Hidden
  )

  if (-not (Test-Path -LiteralPath $File)) {
    Warn "Child '$Name' script not found: $File"
    return $null
  }

  $psi = @{
    FilePath     = 'powershell.exe'
    ArgumentList = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$File`"")
    WorkingDirectory = (Split-Path -Parent $File)
    PassThru    = $true
  }

  if ($Arguments) {
    $psi.ArgumentList += $Arguments
  }
  if ($Hidden) {
    $psi.WindowStyle = 'Hidden'
  }

  $proc = Start-Process @psi
  if ($PidFile) {
    [IO.File]::WriteAllText($PidFile, "$($proc.Id)", [Text.UTF8Encoding]::new($false))
  }

  Log "Started $Name (PID $($proc.Id))"
  return $proc
}

function Test-LlamaServerReady {
  param(
    [string]$Url
  )

  try {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
    return $true
  } catch {
    return $false
  }
}

function Start-LlamaInstance {
  param(
    [string]$Name,
    [string]$ModelPath,
    [int]   $Port,
    [string]$Alias,
    [string]$PidFile
  )

  if (-not (Test-Path -LiteralPath $ModelPath)) {
    throw "Llama model for '$Name' not found: $ModelPath"
  }

  $exe = 'D:\llama-cpp\llama-server.exe'
  if ($env:LLAMA_SERVER_EXE -and (Test-Path -LiteralPath $env:LLAMA_SERVER_EXE)) {
    $exe = $env:LLAMA_SERVER_EXE
  }
  if (-not (Test-Path -LiteralPath $exe)) {
    throw "llama-server.exe not found: $exe"
  }

  $args = @(
    '-m', "`"$ModelPath`"",
    '--port', $Port,
    '--alias', $Alias,
    '--host', '127.0.0.1',
    '--embedding',
    '--n-gpu-layers','999',
    '-t', '2',              # Minimal CPU threads (GPU does heavy lifting)
    '-b', '512',            # Batch size
    '-c', '4096'            # Context size
  )

  Log "Starting llama-server '$Name' (model=$ModelPath, port=$Port)"
  $proc = Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru
  if ($PidFile) {
    [IO.File]::WriteAllText($PidFile, "$($proc.Id)", [Text.UTF8Encoding]::new($false))
  }

  $url = "http://127.0.0.1:$Port"
  $tries = 0
  $maxTries = 120

  while ($tries -lt $maxTries) {
    if (Test-LlamaServerReady -Url $url) {
      Log "llama-server '$Name' is ready on $url after $tries checks"
      return
    }
    Start-Sleep -Seconds 1
    $tries++
  }

  Warn "llama-server '$Name' did not become ready on $url within $maxTries seconds."
}

# -------------------------------
# Paths & environment
# -------------------------------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# If you have a shared paths helper, you can swap this to Get-EchoPaths
$paths = [ordered]@{
  Home  = $ScriptRoot
  Logs  = Join-Path $ScriptRoot 'logs'
  State = Join-Path $ScriptRoot 'state'
}

New-Item -ItemType Directory -Force -Path $paths.Logs  | Out-Null
New-Item -ItemType Directory -Force -Path $paths.State | Out-Null

$env:ECHO_HOME = $paths.Home
Log "ECHO_HOME = $($paths.Home)"

# Models should already be configured via env; fall back to defaults if needed
if (-not $env:ECHO_SMALL_MODEL_PATH) {
  $env:ECHO_SMALL_MODEL_PATH = Join-Path $paths.Home 'models\gemma-3-4b-it-uncensored-dbl-x-q8_0.gguf'
}
if (-not $env:ECHO_MAIN_MODEL_PATH) {
  $env:ECHO_MAIN_MODEL_PATH  = Join-Path $paths.Home 'models\Llama-3.1-128k-Dark-Planet-Uncensored-8B-Q4_k_m.gguf'
}
if (-not $env:ECHO_SMALL_MODEL_NAME) { $env:ECHO_SMALL_MODEL_NAME = 'small' }
if (-not $env:ECHO_MAIN_MODEL_NAME)  { $env:ECHO_MAIN_MODEL_NAME  = 'main' }

# -------------------------------
# Start llama instances (text, on 3060)
# -------------------------------
$smallPidFile = Join-Path $paths.State 'llama-small.pid'
$mainPidFile  = Join-Path $paths.State 'llama-main.pid'

Log "Starting llama-server instances..."
Start-LlamaInstance -Name 'small' -ModelPath $env:ECHO_SMALL_MODEL_PATH -Port 8081 -Alias $env:ECHO_SMALL_MODEL_NAME -PidFile $smallPidFile
Start-LlamaInstance -Name 'main'  -ModelPath $env:ECHO_MAIN_MODEL_PATH  -Port 8080 -Alias $env:ECHO_MAIN_MODEL_NAME  -PidFile $mainPidFile

# -------------------------------
# Start dedicated VISION llama-server on RX 580
# -------------------------------
# This is the *new* offload: Start-VisionServer.ps1 is responsible for
# binding llama-server to GPU1 (Radeon RX 580) using Vulkan and hosting
# the vision model on a separate port (e.g. 8082).
# VisionProbe-Lite will later call that over HTTP.
if (-not $SkipVision) {
  $visionServerScript = Join-Path $paths.Home 'Start-VisionServer.ps1'
  if (Test-Path -LiteralPath $visionServerScript) {
    $visionServerPid = Join-Path $paths.State 'vision_server.pid'
    Start-Child -Name 'VisionServer' -File $visionServerScript -PidFile $visionServerPid -Hidden
    $env:ECHO_VISION_SERVER_URL = 'http://127.0.0.1:8082'
  } else {
    Warn "Vision server script not found at $visionServerScript; vision will not be offloaded to RX 580."
  }
} else {
  Log "SkipVision specified; skipping VisionServer start."
}

# -------------------------------
# Launch Echo components
# -------------------------------
Log "Launching components..."

$echoPidFile   = Join-Path $paths.State 'echo.pid'
$imPidFile     = Join-Path $paths.State 'im.pid'
$visionPidFile = Join-Path $paths.State 'vision.pid'
$whisperPidFile = Join-Path $paths.State 'whisper.pid'
$roomPidFile    = Join-Path $paths.State 'room.pid'
# Whisper: stream mic to inbox
$whisperScript = Join-Path $paths.Home 'tools\Start-WhisperStreamToInbox.ps1'
if (Test-Path -LiteralPath $whisperScript) {
  Start-Child -Name 'Whisper' -File $whisperScript -PidFile $whisperPidFile -Hidden
} else {
  Warn "Child 'Whisper' script not found: $whisperScript"
}

# Room (EchoRoom UI)
if (-not $SkipRoom) {
  $roomScript = Join-Path $paths.Home 'Start-EchoRoom.ps1'
  if (Test-Path -LiteralPath $roomScript) {
    Start-Child -Name 'Room' -File $roomScript -PidFile $roomPidFile
  } else {
    Warn "Child 'Room' script not found: $roomScript"
  }
}


Start-Child -Name 'Echo'   -File (Join-Path $paths.Home 'Start-Echo.ps1')   -PidFile $echoPidFile   -Hidden
Start-Child -Name 'IM'     -File (Join-Path $paths.Home 'Start-IM.ps1')     -PidFile $imPidFile     -Hidden

if (-not $SkipVision) {
  # VisionProbe-Lite: captures screenshots and calls the vision llama-server on RX 580
  Start-Child -Name 'Vision' -File (Join-Path $paths.Home 'Start-VisionProbe-Lite.ps1') -PidFile $visionPidFile -Hidden
}

# -------------------------------
# Wait for main LLM to be ready (health check)
# -------------------------------
$llmUrl = 'http://127.0.0.1:8080'

Log "Waiting for LLM server to be ready..."
$attempts = 0
while ($attempts -lt 60) {
  if (Test-LlamaServerReady -Url $llmUrl) {
    Log ("Server ready after {0} attempts" -f $attempts)
    break
  }
  Start-Sleep -Seconds 1
  $attempts++
}

if ($attempts -ge 60) {
  Warn "Main LLM server did not report ready; Echo may still start but responses could fail."
}

Log "Echo stack is live."
