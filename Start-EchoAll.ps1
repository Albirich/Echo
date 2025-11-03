<#
  Start-EchoAll.ps1 â€” minimal launcher
  Starts only these four components:
    - Start-Echo.ps1
    - Start-IM.ps1
    - Start-EchoRoom.ps1
    - Start-VisionProbe-Lite.ps1
  No Ollama/llama.cpp orchestration, warmups, or extras.
#>

$ErrorActionPreference = 'Stop'

# Resolve home and logs
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $env:ECHO_HOME -or -not (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME = $ScriptRoot }
$HOME_DIR = $env:ECHO_HOME
Set-Location $HOME_DIR

$logs = Join-Path $HOME_DIR 'logs'
$uiPath = Join-Path $HOME_DIR 'ui'
$inboxq = Join-Path $uiPath 'inboxq'
$outbox = Join-Path $uiPath 'outbox.jsonl'
New-Item -ItemType Directory -Force -Path $logs,$uiPath,$inboxq | Out-Null
if (-not (Test-Path -LiteralPath $outbox)) { [IO.File]::WriteAllText($outbox,'',[Text.UTF8Encoding]::new($false)) }

# Ensure state dir and set host flag for VisionLite gating
$state = Join-Path $HOME_DIR 'state'
New-Item -ItemType Directory -Force -Path $state | Out-Null
$hostFlag = Join-Path $state 'host.flag'
$env:ECHO_HOST_FLAG = $hostFlag
if (-not (Test-Path -LiteralPath $hostFlag)) { [IO.File]::WriteAllText($hostFlag,'ok',[Text.UTF8Encoding]::new($false)) }

# Prefer llama.cpp for Chat + IM per user config
$env:ECHO_USE_LLAMA_CPP = '1'
$env:ECHO_IM_USE_LLAMA_CPP = '1'
# Ensure specific gguf models are selected
# Prefer Noromaid 7B Q4_K_M for chat
$desiredChat = (Join-Path $HOME_DIR 'models\nsfw-6b-q2_k.gguf')
$fallbackChat = (Join-Path $HOME_DIR 'models\athirdpath-NSFW_DPO_Noromaid-7b-Q4_K_M.gguf')
$altGemma    = (Join-Path $HOME_DIR 'models\gemma-3-4b-it-uncensored-dbl-x-q8_0.gguf')
if (Test-Path -LiteralPath $desiredChat) {
  $env:ECHO_LLAMACPP_MODEL = $desiredChat
} elseif (Test-Path -LiteralPath $fallbackChat) {
  $env:ECHO_LLAMACPP_MODEL = $fallbackChat
} elseif (Test-Path -LiteralPath $altGemma) {
  $env:ECHO_LLAMACPP_MODEL = $altGemma
} else {
  if ($env:ECHO_LLAMACPP_MODEL) { Remove-Item Env:ECHO_LLAMACPP_MODEL -ErrorAction SilentlyContinue }
}
$chatModelMsg = '(auto)'
if ($env:ECHO_LLAMACPP_MODEL) { $chatModelMsg = $env:ECHO_LLAMACPP_MODEL }
Write-Host ("[EchoAll] Chat model: {0}" -f $chatModelMsg)
$env:ECHO_ROUTER_LLAMACPP_MODEL = (Join-Path $HOME_DIR 'models\Nidum-Limitless-Gemma-2B-Q4_K_M.gguf')
Write-Host ("[EchoAll] Router model: {0}" -f $env:ECHO_ROUTER_LLAMACPP_MODEL)
$env:ECHO_IM_LLAMACPP_MODEL = (Join-Path $HOME_DIR 'models\Nidum-Limitless-Gemma-2B-Q4_K_M.gguf')

# For now: force ALL components to use the IM model if present
try {
  if (Test-Path -LiteralPath $env:ECHO_IM_LLAMACPP_MODEL) {
    $env:ECHO_LLAMACPP_MODEL      = $env:ECHO_IM_LLAMACPP_MODEL
    $env:ECHO_ROUTER_LLAMACPP_MODEL = $env:ECHO_IM_LLAMACPP_MODEL
    Write-Host ("[EchoAll] Forcing all models to IM model: {0}" -f $env:ECHO_IM_LLAMACPP_MODEL)
  }
} catch {}

  # Prefer GPU across all components
# Ollama: offload as many layers as possible (harmless if unused)
$env:OLLAMA_NUM_GPU = '999'
# Avoid forcing IM to Ollama
if ($env:ECHO_IM_BACKEND) { Remove-Item Env:ECHO_IM_BACKEND -ErrorAction SilentlyContinue }
# Reduce CPU usage while using CUDA backend
$env:ECHO_LLAMA_THREADS = '3'
$env:ECHO_LLAMA_MAIN_GPU = '0'
# Llama batching (lower -> less CPU/mem spikes)
  $env:ECHO_LLAMA_BATCH = '512'
$env:ECHO_LLAMA_UBATCH = '128'

  # Warmers start moved below Start-Child

# Simple child launcher (hidden, redirects to logs)
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

Write-Host "[EchoAll] Launching minimal Echo stack..."

# Start llama.cpp server (replaces resident worker)
try {
  if (-not $env:ECHO_LLAMA_SERVER -or $env:ECHO_LLAMA_SERVER.Trim() -eq '') { $env:ECHO_LLAMA_SERVER = 'http://127.0.0.1:8080' }
  $llamaServer = Start-Child -Name 'llama-server' -File (Join-Path $HOME_DIR 'tools\Start-LlamaServer.ps1') -WorkingDirectory $HOME_DIR
  # Record PID for clean shutdown
  [IO.File]::WriteAllText((Join-Path $state 'server.launcher.pid'), [string]$llamaServer.Process.Id)
} catch {
  Write-Host ("[EchoAll] WARNING: Failed to start llama-server: {0}" -f $_.Exception.Message)
}

# Start background warmers (keep llama-cpp hot without a server)
try {
  if ($llamaServer -and $llamaServer.Process -and $llamaServer.Process.Id) {
    Write-Host "[EchoAll] Warmers: skipped (llama-server running)"
    throw 'skip-warmers'
  }
  $llamaExe = if ($env:LLAMA_EXE -and (Test-Path $env:LLAMA_EXE)) { $env:LLAMA_EXE } else { 'D:\\llama-cpp\\llama-cli.exe' }
  $routerModel = if ($env:ECHO_ROUTER_LLAMACPP_MODEL -and (Test-Path $env:ECHO_ROUTER_LLAMACPP_MODEL)) { $env:ECHO_ROUTER_LLAMACPP_MODEL } else { Join-Path $HOME_DIR 'models\\Nidum-Limitless-Gemma-2B-Q4_K_M.gguf' }
  $chatModel   = if ($env:ECHO_LLAMACPP_MODEL -and (Test-Path $env:ECHO_LLAMACPP_MODEL)) { $env:ECHO_LLAMACPP_MODEL } else { Join-Path $HOME_DIR 'models\\athirdpath-NSFW_DPO_Noromaid-7b-Q4_K_M.gguf' }

  $routerGpu = '20'
  try { if ($env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { $routerGpu = $env:ECHO_LLAMA_GPU_LAYERS } } catch {}
  $chatGpu = '35'
  try { if ($env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { $chatGpu = $env:ECHO_LLAMA_GPU_LAYERS } } catch {}

  $routerWarm = Start-Child -Name 'warm-router' -File (Join-Path $HOME_DIR 'tools\\Keep-LlamaWarm.ps1') -WorkingDirectory $HOME_DIR -Args @('-ModelPath',$routerModel,'-LlamaExe',$llamaExe,'-IntervalSec','240','-CtxSize','1024','-GpuLayers', $routerGpu)
  $chatWarm   = Start-Child -Name 'warm-chat'   -File (Join-Path $HOME_DIR 'tools\\Keep-LlamaWarm.ps1') -WorkingDirectory $HOME_DIR -Args @('-ModelPath',$chatModel,'-LlamaExe',$llamaExe,'-IntervalSec','300','-CtxSize','2048','-GpuLayers', $chatGpu)

  # Record PID files for clean shutdown
  [IO.File]::WriteAllText((Join-Path $state 'warm-router.pid'), [string]$routerWarm.Process.Id)
  [IO.File]::WriteAllText((Join-Path $state 'warm-chat.pid'),   [string]$chatWarm.Process.Id)
} catch { 
    # Warmers disabled (resident worker keeps model hot)
    Write-Host "[EchoAll] Warmers: disabled"
  }


# --- Minimal Ollama ensure + warmup for qwen2.5vl:3b ---
function Test-OllamaReachable { param([int]$TimeoutSec=2)
  try {
    $ollamaHost = if ($env:OLLAMA_HOST -and $env:OLLAMA_HOST.Trim()) { $env:OLLAMA_HOST.TrimEnd('/') } else { 'http://127.0.0.1:11434' }
    $uri  = $ollamaHost + '/api/tags'
    Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec | Out-Null
    return $true
  } catch { return $false }
}

function Get-OllamaExe {
  try { $cmd = (Get-Command 'ollama.exe' -ErrorAction SilentlyContinue).Source; if ($cmd) { return $cmd } } catch {}
  $cand = 'C:\\Program Files\\Ollama\\ollama.exe'
  if (Test-Path -LiteralPath $cand) { return $cand }
  return $null
}

function Ensure-OllamaUp {
  if (Test-OllamaReachable 2) { Write-Host '[EchoAll] Ollama reachable.'; return }
  # Try service first
  $svc = Get-Service -Name 'Ollama' -ErrorAction SilentlyContinue
  if ($svc) {
    if ($svc.Status -ne 'Running') {
      try { Start-Service -Name 'Ollama' -ErrorAction Stop; Write-Host '[EchoAll] Starting Ollama service...' } catch { Write-Host '[EchoAll] Could not start Ollama service; will try ollama serve.' }
    }
    for ($i=0; $i -lt 15; $i++) { if (Test-OllamaReachable 1) { Write-Host '[EchoAll] Ollama reachable (service).'; return }; Start-Sleep -Milliseconds 800 }
  }
  # Fallback to child process
  $exe = Get-OllamaExe
  if ($exe) {
    $ts = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $out = Join-Path $logs ("ollama-" + $ts + '.out.log')
    $err = Join-Path $logs ("ollama-" + $ts + '.err.log')
    $psi = @{ FilePath=$exe; ArgumentList=@('serve'); WorkingDirectory=$HOME_DIR; RedirectStandardOutput=$out; RedirectStandardError=$err; WindowStyle='Hidden'; PassThru=$true }
    $p = Start-Process @psi
    Write-Host ("[EchoAll] Started 'ollama serve' (PID {0})" -f $p.Id)
    for ($i=0; $i -lt 20; $i++) { if (Test-OllamaReachable 1) { Write-Host '[EchoAll] Ollama reachable (serve).'; break }; Start-Sleep -Milliseconds 1000 }
  } else {
    Write-Host '[EchoAll] WARNING: ollama executable not found.'
  }
}

function Warmup-OllamaModel { param([string]$Model)
  if (-not (Test-OllamaReachable 2)) { Write-Host '[EchoAll] Skipping warmup (Ollama not reachable).'; return }
  try {
    $body = @{ model=$Model; stream=$false; messages=@(@{role='system';content='warmup'},@{role='user';content='hi'}) } | ConvertTo-Json -Depth 6
    $base = 'http://127.0.0.1:11434'
    if ($env:OLLAMA_HOST -and $env:OLLAMA_HOST.Trim()) { $base = $env:OLLAMA_HOST.TrimEnd('/') }
    $uri = $base + '/api/chat'
    Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180 | Out-Null
    Write-Host ("[EchoAll] Warmed model: {0}" -f $Model)
  } catch { Write-Host ("[EchoAll] Warmup failed for {0}: {1}" -f $Model, $_.Exception.Message) }
}

Ensure-OllamaUp
Warmup-OllamaModel 'qwen2.5vl:3b'
Warmup-OllamaModel 'qwen2.5:3b'

# Launch exactly the requested four components
$chat   = Start-Child -Name 'start-echo'               -File (Join-Path $HOME_DIR 'Start-Echo.ps1')            -WorkingDirectory $HOME_DIR
$im     = Start-Child -Name 'start-im'                 -File (Join-Path $HOME_DIR 'Start-IM.ps1')              -WorkingDirectory $HOME_DIR
$room   = Start-Child -Name 'start-echoroom'           -File (Join-Path $HOME_DIR 'Start-EchoRoom.ps1')        -WorkingDirectory $HOME_DIR
$vision = Start-Child -Name 'start-visionprobe-lite'   -File (Join-Path $HOME_DIR 'Start-VisionProbe-Lite.ps1')-WorkingDirectory $HOME_DIR

# Speech-to-Text: Whisper stream -> inboxq
$whisper = $null
try {
  $whisper = Start-Child -Name 'start-whisper' -File (Join-Path $HOME_DIR 'tools\Start-WhisperStreamToInbox.ps1') -WorkingDirectory $HOME_DIR
} catch { Write-Host ("[EchoAll] WARNING: Whisper launcher failed: {0}" -f $_.Exception.Message) }

Write-Host ""
Write-Host "[EchoAll] ==============================================="
Write-Host "[EchoAll]   Echo minimal stack launched."
if ($chat)   { Write-Host ("[EchoAll]   Chat     PID: {0}" -f $chat.Process.Id) }
if ($im)     { Write-Host ("[EchoAll]   IM       PID: {0}" -f $im.Process.Id) }
if ($room)   { Write-Host ("[EchoAll]   EchoRoom PID: {0}" -f $room.Process.Id) }
if ($vision) { Write-Host ("[EchoAll]   Vision   PID: {0}" -f $vision.Process.Id) }
if ($whisper) { Write-Host ("[EchoAll]   Whisper  PID: {0}" -f $whisper.Process.Id) }
Write-Host ("[EchoAll]   Logs: {0} (per-process .out/.err files)" -f $logs)
Write-Host "[EchoAll] ==============================================="
Write-Host ""

# Exit after launching; children continue independently
