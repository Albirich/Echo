# Start-EchoAll.ps1 – launch Echo stack (chat + IM + Vision + UI) and ensure Ollama is running + warmed
# Windows PowerShell 5.1+

$ErrorActionPreference = 'Stop'

# ---------------------------
# Paths & Env
# ---------------------------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $env:ECHO_HOME -or -not (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME = $ScriptRoot }
$HOME_DIR = $env:ECHO_HOME
Set-Location $HOME_DIR

$logs = Join-Path $HOME_DIR 'logs'
$uiDirCandidates = @(
  (Join-Path $HOME_DIR 'room\echo-room'),
  (Join-Path $HOME_DIR 'echo-room'),
  (Join-Path $HOME_DIR 'room')
)

# Ensure bus
$uiPath = Join-Path $HOME_DIR 'ui'
$inboxq = Join-Path $uiPath 'inboxq'
$outbox = Join-Path $uiPath 'outbox.jsonl'
New-Item -ItemType Directory -Force -Path $logs,$uiPath,$inboxq | Out-Null
if (-not (Test-Path $outbox)) {
  [IO.File]::WriteAllText($outbox,'',[Text.UTF8Encoding]::new($false))
}

# ---------------------------
# Ollama host & models (single source of truth)
# ---------------------------
if (-not $env:OLLAMA_HOST -or $env:OLLAMA_HOST -eq '') { $env:OLLAMA_HOST = 'http://127.0.0.1:11434' }

# Preferred defaults
$defaultMain   = 'dolphin-mistral:7b'
$defaultIM     = 'qwen2.5:3b'
$defaultVision = 'llava:7b'

# Normalize inputs
if ($env:ECHO_CHAT_MODEL   -and $env:ECHO_CHAT_MODEL.Trim())   { $env:ECHO_CHAT_MODEL   = $env:ECHO_CHAT_MODEL.Trim()   }
if ($env:ECHO_IM_MODEL     -and $env:ECHO_IM_MODEL.Trim())     { $env:ECHO_IM_MODEL     = $env:ECHO_IM_MODEL.Trim()     }
if ($env:ECHO_VISION_MODEL -and $env:ECHO_VISION_MODEL.Trim()) { $env:ECHO_VISION_MODEL = $env:ECHO_VISION_MODEL.Trim() }
if ($env:ECHO_MODEL        -and $env:ECHO_MODEL.Trim())        { $env:ECHO_MODEL        = $env:ECHO_MODEL.Trim()        }

# Prefer config\im.http.json model if present (overrides any pre-set env var in this process)
$imCfgPath = Join-Path $HOME_DIR 'config\im.http.json'
if (Test-Path $imCfgPath) {
  try {
    $imCfg = Get-Content -LiteralPath $imCfgPath -Raw | ConvertFrom-Json
    if ($imCfg -and $imCfg.model -and $imCfg.model.Trim()) {
      $env:ECHO_IM_MODEL = $imCfg.model.Trim()
      [Environment]::SetEnvironmentVariable('ECHO_IM_MODEL', $env:ECHO_IM_MODEL, 'Process') | Out-Null
    }
  } catch { }
}

# If caller set ECHO_MODEL explicitly, honor it; else follow ECHO_CHAT_MODEL; else default
if (-not $env:ECHO_MODEL -or -not $env:ECHO_MODEL.Trim()) {
  if ($env:ECHO_CHAT_MODEL -and $env:ECHO_CHAT_MODEL.Trim()) {
    $env:ECHO_MODEL = $env:ECHO_CHAT_MODEL
  } else {
    $env:ECHO_MODEL = $defaultMain
  }
}
# Keep CHAT_MODEL in sync for clarity
if (-not $env:ECHO_CHAT_MODEL -or -not $env:ECHO_CHAT_MODEL.Trim()) { $env:ECHO_CHAT_MODEL = $env:ECHO_MODEL }

# IM default
if (-not $env:ECHO_IM_MODEL -or -not $env:ECHO_IM_MODEL.Trim()) { $env:ECHO_IM_MODEL = $defaultIM }

# Vision default
if (-not $env:VISION_MODEL -or -not $env:VISION_MODEL.Trim()) { $env:VISION_MODEL = $defaultVision }

Write-Host ("[EchoAll] OLLAMA_HOST   = {0}" -f $env:OLLAMA_HOST)
Write-Host ("[EchoAll] Main model    = {0}" -f $env:ECHO_MODEL)
Write-Host ("[EchoAll] IM model      = {0}" -f $env:ECHO_IM_MODEL)
Write-Host ("[EchoAll] Vision model  = {0}" -f $env:VISION_MODEL)

# ---------------------------
# Ollama: ensure server is running
# ---------------------------
function Test-OllamaReachable([int]$TimeoutSec = 3) {
  try {
    Invoke-RestMethod -Uri ($env:OLLAMA_HOST.TrimEnd('/') + '/api/tags') -TimeoutSec $TimeoutSec | Out-Null
    return $true
  } catch { return $false }
}

function Get-OllamaExe {
  $cmd = $null
  try { $cmd = (Get-Command 'ollama' -ErrorAction SilentlyContinue).Source } catch {}
  if (-not $cmd -and (Test-Path 'C:\Program Files\Ollama\ollama.exe')) { $cmd = 'C:\Program Files\Ollama\ollama.exe' }
  return $cmd
}

function Ensure-OllamaUp {
  if (Test-OllamaReachable 2) { Write-Host "[EchoAll] Ollama reachable."; return }

  # Try Windows service first
  $svc = Get-Service -Name 'Ollama' -ErrorAction SilentlyContinue
  if ($svc) {
    if ($svc.Status -ne 'Running') {
      try {
        Start-Service -Name 'Ollama' -ErrorAction Stop
        Write-Host "[EchoAll] Starting Ollama service..."
      } catch {
        Write-Host "[EchoAll] NOTE: Failed to start Ollama service (need admin?). Will try 'ollama serve'."
      }
    }
    # Wait up to ~20s for service to respond
    for ($i=0; $i -lt 20; $i++) {
      if (Test-OllamaReachable 1) { Write-Host "[EchoAll] Ollama reachable (service)."; return }
      Start-Sleep -Milliseconds 1000
    }
  }

  # Fall back: start 'ollama serve' as a child process
  $ollamaExe = Get-OllamaExe
  if ($ollamaExe) {
    $ts = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $out = Join-Path $logs ("ollama-{0}.out.log" -f $ts)
    $err = Join-Path $logs ("ollama-{0}.err.log" -f $ts)
    $psi = @{
      FilePath               = $ollamaExe
      ArgumentList           = @('serve')
      WorkingDirectory       = $HOME_DIR
      RedirectStandardOutput = $out
      RedirectStandardError  = $err
      WindowStyle            = 'Hidden'
      PassThru               = $true
    }
    $p = Start-Process @psi
    Write-Host ("[EchoAll] Started 'ollama serve' (PID {0})" -f $p.Id)
    # Wait up to ~30s for it to come up
    for ($i=0; $i -lt 30; $i++) {
      if (Test-OllamaReachable 1) { Write-Host "[EchoAll] Ollama reachable (serve)."; return }
      Start-Sleep -Milliseconds 1000
    }
  } else {
    Write-Host "[EchoAll] WARNING: 'ollama' not found in PATH and default install path missing."
  }

  if (-not (Test-OllamaReachable 2)) {
    Write-Host "[EchoAll] ERROR: Ollama still not reachable. Continuing without warmup."
  }
}

Ensure-OllamaUp

# ---------------------------
# Warm-up models (if reachable)
# ---------------------------
function Invoke-ModelWarmup([string]$Model, [string]$Label) {
  try {
    $body = @{
      model    = $Model
      stream   = $false
      messages = @(
        @{ role='system'; content = 'warmup' },
        @{ role='user';   content = 'hi' }
      )
    } | ConvertTo-Json -Depth 6

    $uri = $env:OLLAMA_HOST.TrimEnd('/') + '/api/chat'
    Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180 | Out-Null
    Write-Host ("[EchoAll] Warmed {0} model: {1}" -f $Label, $Model)
  } catch {
    Write-Host ("[EchoAll] Warmup skipped for {0} ({1}): {2}" -f $Label, $Model, $_.Exception.Message)
  }
}

$doWarm = $true
if ($env:ECHO_WARMUP -and $env:ECHO_WARMUP -match '^(0|false|no)$') { $doWarm = $false }
if ($doWarm -and (Test-OllamaReachable 2)) {
  Invoke-ModelWarmup $env:ECHO_MODEL 'chat'
  if ($env:ECHO_IM_MODEL -and $env:ECHO_IM_MODEL.Trim()) {
    Invoke-ModelWarmup $env:ECHO_IM_MODEL 'IM'
  }
  if ($env:VISION_MODEL -and $env:VISION_MODEL.Trim()) {
    Invoke-ModelWarmup $env:VISION_MODEL 'vision'
  }
} elseif ($doWarm) {
  Write-Host "[EchoAll] Skipping warmup (Ollama not reachable)."
}

# ---------------------------
# Child launcher (hidden windows)
# ---------------------------
function Start-Child {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$File,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [string[]]$Args = @()
  )
  $ts = (Get-Date -Format 'yyyyMMdd_HHmmss')
  $out = Join-Path $logs ("{0}-{1}.out.log" -f $Name, $ts)
  $err = Join-Path $logs ("{0}-{1}.err.log" -f $Name, $ts)
  $psi = @{
    FilePath               = 'powershell'
    ArgumentList           = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $File) + $Args
    WorkingDirectory       = $WorkingDirectory
    RedirectStandardOutput = $out
    RedirectStandardError  = $err
    WindowStyle            = 'Hidden'
    PassThru               = $true
  }
  $p = Start-Process @psi
  Write-Host ("[EchoAll] Started {0} (PID {1})" -f $Name, $p.Id)
  Write-Host ("[EchoAll]   -> STDOUT: {0}" -f $out)
  Write-Host ("[EchoAll]   -> STDERR: {0}" -f $err)
  return [pscustomobject]@{ Name=$Name; Process=$p; Out=$out; Err=$err }
}

# ---------------------------
# Launch Chat + IM + Vision
# ---------------------------
$chat   = Start-Child -Name 'echo-chat'   -File (Join-Path $HOME_DIR 'Start-Echo.ps1') -WorkingDirectory $HOME_DIR
$im     = Start-Child -Name 'echo-im'     -File (Join-Path $HOME_DIR 'Start-IM.ps1')   -WorkingDirectory $HOME_DIR
$env:ECHO_HOST_FLAG = Join-Path $HOME_DIR 'state\vision.enabled'
$flagFile = $env:ECHO_HOST_FLAG
if (-not (Test-Path $flagFile)) {
  New-Item -ItemType File -Path $flagFile -Force | Out-Null
}
$vision = Start-Child -Name 'echo-vision' -File (Join-Path $HOME_DIR 'Start-VisionProbe-Burst.ps1') -WorkingDirectory $HOME_DIR -Args @('-BurstIntervalSec','10')

# ---------------------------
# Launch UI (if present)
# ---------------------------
$uiDir = $uiDirCandidates | Where-Object { Test-Path (Join-Path $_ 'package.json') } | Select-Object -First 1
$ui = $null
if ($uiDir) {
  $ud = Join-Path $HOME_DIR '_userdata'
  $cd = Join-Path $HOME_DIR '_cache'
  New-Item -ItemType Directory -Force -Path $ud,$cd | Out-Null

  $ts = (Get-Date -Format 'yyyyMMdd_HHmmss')
  $out = Join-Path $logs ("echo-ui-{0}.out.log" -f $ts)
  $err = Join-Path $logs ("echo-ui-{0}.err.log" -f $ts)

  $args = @(
    '/c', "cd /d `"$uiDir`" && npx electron . --user-data-dir=`"$ud`" --disk-cache-dir=`"$cd`" --disable-gpu-shader-disk-cache"
  )
  $psi = @{
    FilePath               = 'cmd.exe'
    ArgumentList           = $args
    WorkingDirectory       = $HOME_DIR
    RedirectStandardOutput = $out
    RedirectStandardError  = $err
    WindowStyle            = 'Hidden'
    PassThru               = $true
  }
  $p = Start-Process @psi
  $ui = [pscustomobject]@{ Name='echo-ui'; Process=$p; Out=$out; Err=$err }
  Write-Host ("[EchoAll] Started echo-ui (PID {0})" -f $p.Id)
  Write-Host ("[EchoAll]   -> STDOUT: {0}" -f $out)
  Write-Host ("[EchoAll]   -> STDERR: {0}" -f $err)
} else {
  Write-Host "[EchoAll] UI not found (no package.json under room\echo-room, echo-room, or room)."
}

Write-Host ""
Write-Host "[EchoAll] ==============================================="
Write-Host "[EchoAll]   Echo stack launched."
if ($chat)   { Write-Host ("[EchoAll]   Chat   PID: {0}" -f $chat.Process.Id) }
if ($im)     { Write-Host ("[EchoAll]   IM     PID: {0}" -f $im.Process.Id) }
if ($vision) { Write-Host ("[EchoAll]   Vision PID: {0}" -f $vision.Process.Id) }
if ($ui)     { Write-Host ("[EchoAll]   UI     PID: {0}" -f $ui.Process.Id) }
Write-Host ("[EchoAll]   Logs: {0} (per-process .out/.err files)" -f $logs)
Write-Host "[EchoAll] ==============================================="
Write-Host ""

# ---------------------------
# Monitor children (simple)
# ---------------------------
$procs = @()
if ($chat)   { $procs += $chat }
if ($im)     { $procs += $im }
if ($vision) { $procs += $vision }
if ($ui)     { $procs += $ui }

while ($true) {
  foreach ($c in @($procs)) {
    try { Get-Process -Id $c.Process.Id -ErrorAction Stop | Out-Null }
    catch {
      Write-Host ("WARNING: [EchoAll] Detected child exit: {0} PID {1}" -f $c.Name, $c.Process.Id)
      $procs = @($procs | Where-Object { $_.Process.Id -ne $c.Process.Id })
    }
  }
  Start-Sleep -Milliseconds 500
  if ($procs.Count -eq 0) { break }
}
