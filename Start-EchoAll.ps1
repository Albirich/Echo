# Start-EchoAll.ps1 — PS 5.1 compatible launcher
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'
$PSModuleAutoLoadingPreference = 'None'

# Explicitly import core modules when autoloading is disabled. Without these,
# basic cmdlets like Test-Path and New-Item may be unavailable in PowerShell 5.1.
Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
Import-Module Microsoft.PowerShell.Utility    -ErrorAction SilentlyContinue

# ---- console writers (avoid Write-Host) ----
function Write-Info([string]$msg) { [Console]::WriteLine("[EchoAll]       {0}" -f $msg) }
function Write-Warn([string]$msg) { [Console]::WriteLine("[EchoAll][WARN] {0}" -f $msg) }
function Write-Err ([string]$msg) { [Console]::WriteLine("[EchoAll][ERR]  {0}" -f $msg) }

# ---- helpers ----
function Assert-Path([string]$Path,[string]$Kind) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    throw ("Missing {0}: {1}" -f $Kind, $Path)
    # or: throw "Missing ${Kind}: ${Path}"
  }
}

function Join-Home([string]$rel) {
  return [IO.Path]::Combine($env:ECHO_HOME, $rel)
}

# ---- resolve ECHO_HOME and base dirs ----
try {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} catch {
  # Fall back to the current working directory without relying on Get-Location
  $scriptDir = [System.IO.Directory]::GetCurrentDirectory()
}
if (-not $env:ECHO_HOME -or -not (Test-Path -LiteralPath $env:ECHO_HOME)) { $env:ECHO_HOME = $scriptDir }
Set-Location $env:ECHO_HOME

$logsDir   = Join-Home 'logs'
$uiDir     = Join-Home 'ui'
$inboxDir  = Join-Home 'ui\inboxq'
$outboxJl  = Join-Home 'ui\outbox.jsonl'
$stateDir  = Join-Home 'state'
New-Item -ItemType Directory -Force -Path $logsDir,$uiDir,$inboxDir,$stateDir | Out-Null
if (-not (Test-Path -LiteralPath $outboxJl)) { [IO.File]::WriteAllText($outboxJl,'',[Text.UTF8Encoding]::new($false)) }

# host flag some tools check
$hostFlag = Join-Home 'state\host.flag'
$env:ECHO_HOST_FLAG = $hostFlag
if (-not (Test-Path -LiteralPath $hostFlag)) { [IO.File]::WriteAllText($hostFlag,'ok',[Text.UTF8Encoding]::new($false)) }

# ---- model selection (unified to Noromaid 7B) ----
$noromaid = Join-Home 'models\athirdpath-NSFW_DPO_Noromaid-7b-Q4_K_M.gguf'
$altGemma = Join-Home 'models\gemma-3-4b-it-uncensored-dbl-x-q8_0.gguf'

if (Test-Path -LiteralPath $noromaid) {
  $env:ECHO_LLAMACPP_MODEL = $noromaid
} elseif (Test-Path -LiteralPath $altGemma) {
  $env:ECHO_LLAMACPP_MODEL = $altGemma
} else {
  Remove-Item Env:ECHO_LLAMACPP_MODEL -ErrorAction SilentlyContinue
}

if ($env:ECHO_LLAMACPP_MODEL) { Write-Info ("Chat model: {0}" -f $env:ECHO_LLAMACPP_MODEL) } else { Write-Info "Chat model: (auto)" }
$env:ECHO_ROUTER_LLAMACPP_MODEL = $env:ECHO_LLAMACPP_MODEL
if ($env:ECHO_ROUTER_LLAMACPP_MODEL) { Write-Info ("Router model: {0}" -f $env:ECHO_ROUTER_LLAMACPP_MODEL) } else { Write-Info "Router model: (auto)" }
$env:ECHO_IM_LLAMACPP_MODEL = $env:ECHO_LLAMACPP_MODEL

# force all to IM model if present
if ($env:ECHO_IM_LLAMACPP_MODEL) {
  $env:ECHO_LLAMACPP_MODEL        = $env:ECHO_IM_LLAMACPP_MODEL
  $env:ECHO_ROUTER_LLAMACPP_MODEL = $env:ECHO_IM_LLAMACPP_MODEL
  Write-Info ("Forcing all models to IM model: {0}" -f $env:ECHO_IM_LLAMACPP_MODEL)
}

# ---- low-CPU defaults for llama.cpp bits ----
$env:ECHO_LLAMA_THREADS     = '1'
$env:ECHO_LLAMA_BATCH       = '512'
$env:ECHO_LLAMA_UBATCH      = '128'
$env:ECHO_LLAMA_MAIN_GPU    = '0'
$env:ECHO_LLAMA_GPU_LAYERS  = '100'
if (-not $env:ECHO_IM_THREADS      -or [string]::IsNullOrWhiteSpace($env:ECHO_IM_THREADS))      { $env:ECHO_IM_THREADS      = '1' }
if (-not $env:ECHO_VISION_THREADS  -or [string]::IsNullOrWhiteSpace($env:ECHO_VISION_THREADS))  { $env:ECHO_VISION_THREADS  = '1' }

# server hints (harmless if unused)
if (-not $env:ECHO_LLAMA_SERVER -or -not $env:ECHO_LLAMA_SERVER.Trim()) { $env:ECHO_LLAMA_SERVER = "http://127.0.0.1:8080/v1" }
if (-not $env:ECHO_LLAMA_MODEL  -or -not $env:ECHO_LLAMA_MODEL.Trim())  { $env:ECHO_LLAMA_MODEL  = "echo" }

# ---- VisionLite via Ollama: qwen2.5-vl:3b ----
function Normalize-QwenTag([string]$s){
  if (-not $s) { return $null }
  # accept "qwen2.5vl" and make it "qwen2.5-vl"
  return ($s -replace 'qwen2\.5vl','qwen2.5-vl')
}
$env:ECHO_VISION_BACKEND = 'ollama'
if (-not $env:OLLAMA_HOST -or [string]::IsNullOrWhiteSpace($env:OLLAMA_HOST)) { $env:OLLAMA_HOST = 'http://127.0.0.1:11434' }
if (-not $env:ECHO_VISION_MODEL -or [string]::IsNullOrWhiteSpace($env:ECHO_VISION_MODEL)) { $env:ECHO_VISION_MODEL = 'qwen2.5-vl:3b' }
$env:ECHO_VISION_MODEL = Normalize-QwenTag($env:ECHO_VISION_MODEL)
$env:ECHO_SCREEN_JSONL = Join-Home 'ui\screen.captions.jsonl'
if (-not $env:OLLAMA_NO_CPU_FALLBACK -or [string]::IsNullOrWhiteSpace($env:OLLAMA_NO_CPU_FALLBACK)) { $env:OLLAMA_NO_CPU_FALLBACK = '1' }
if (-not $env:OLLAMA_NUM_PARALLEL    -or [string]::IsNullOrWhiteSpace($env:OLLAMA_NUM_PARALLEL))    { $env:OLLAMA_NUM_PARALLEL    = '1' }

# Point Ollama to local models dir if present (for spawned server)
if (-not $env:OLLAMA_MODELS -or [string]::IsNullOrWhiteSpace($env:OLLAMA_MODELS)) {
  $modelsRoot = Join-Home 'models'
  if (Test-Path -LiteralPath (Join-Path $modelsRoot 'manifests')) {
    $env:OLLAMA_MODELS = $modelsRoot
    Write-Info ("Using OLLAMA_MODELS = {0}" -f $env:OLLAMA_MODELS)
  }
}

# ---- Ollama warmup helpers ----
function Get-OllamaWarmTimeoutSec {
  try { if ($env:ECHO_VISION_WARMUP_TIMEOUT -and $env:ECHO_VISION_WARMUP_TIMEOUT.Trim()) { return [int]$env:ECHO_VISION_WARMUP_TIMEOUT } } catch {}
  return 30
}

function New-WarmupImagePath {
  try {
    $shots = Join-Home 'sense\screenshots'
    New-Item -ItemType Directory -Force -Path $shots | Out-Null
    $cand = Get-ChildItem -LiteralPath $shots -Filter 'frame_*.jpg' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($cand -and $cand.FullName) { return $cand.FullName }
    try { Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue } catch {}
    $bmp = New-Object System.Drawing.Bitmap 320,180
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $brush = [System.Drawing.Brushes]::LightGray
    $gfx.FillRectangle($brush, 0,0,320,180)
    $path = Join-Path $shots 'warmup.jpg'
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $gfx.Dispose(); $bmp.Dispose()
    return $path
  } catch { return $null }
}

function Resolve-OllamaModelTag {
  param([string]$OllamaHost,[string]$Desired)
  try {
    if (-not $OllamaHost -or [string]::IsNullOrWhiteSpace($OllamaHost)) { $OllamaHost = 'http://127.0.0.1:11434' }
    $uri = ($OllamaHost.TrimEnd('/')) + '/api/tags'
    $resp = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 5
    $tags = @()
    if ($resp -and $resp.models) { foreach ($m in $resp.models) { if ($m.name) { $tags += [string]$m.name } } }
    if ($tags.Count -eq 0) { return $Desired }
    foreach ($t in $tags) { if ($t -ieq $Desired) { return $t } }
    $alt = $null
    if ($Desired -match 'qwen2\.5-vl') { $alt = ($Desired -replace 'qwen2\.5-vl','qwen2.5vl') }
    elseif ($Desired -match 'qwen2\.5vl') { $alt = ($Desired -replace 'qwen2\.5vl','qwen2.5-vl') }
    if ($alt) { foreach ($t in $tags) { if ($t -ieq $alt) { return $t } } }
    $gpu = @($tags | Where-Object { $_ -match 'qwen' -and $_ -match 'vl' -and $_ -match '3b' -and $_ -match 'gpu' })
    if ($gpu -and $gpu.Count -gt 0) { return $gpu[0] }
    foreach ($t in $tags) { if ($t -match 'qwen' -and $t -match 'vl' -and $t -match '3b') { return $t } }
    return $Desired
  } catch { return $Desired }
}

function Warm-OllamaVision {
  param([string]$OllamaHost,[string]$Model)
  try {
    if (-not $OllamaHost -or [string]::IsNullOrWhiteSpace($OllamaHost)) { $OllamaHost = 'http://127.0.0.1:11434' }
    if (-not $Model -or [string]::IsNullOrWhiteSpace($Model)) { $Model = 'qwen2.5-vl:3b' }
    $Model = Normalize-QwenTag($Model)
    $Resolved = Resolve-OllamaModelTag -OllamaHost $OllamaHost -Desired $Model
    if ($Resolved -ne $Model) { Write-Info ("Warmup resolved model: {0} -> {1}" -f $Model, $Resolved); $Model = $Resolved }
    $timeout = Get-OllamaWarmTimeoutSec

    try {
      $pullBody = @{ name = $Model; stream = $false } | ConvertTo-Json -Depth 4
      $null = Invoke-RestMethod -Method Post -Uri ("{0}/api/pull" -f $OllamaHost.TrimEnd('/')) -ContentType 'application/json' -Body $pullBody -TimeoutSec $timeout
    } catch { Write-Warn ("Warmup pull warning: {0}" -f $_.Exception.Message) }

    $imgPath = New-WarmupImagePath
    $b64 = $null
    if ($imgPath -and (Test-Path -LiteralPath $imgPath)) { $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($imgPath)) }
    $prompt = "Warmup. Describe briefly. <desc>ok</desc>"

    try {
      $bodyGen = @{ model = $Model; prompt = $prompt; stream = $false };
      if ($b64) { $bodyGen.images = @($b64) }
      $bodyGen = $bodyGen | ConvertTo-Json -Depth 6
      $resp = Invoke-RestMethod -Method Post -Uri ("{0}/api/generate" -f $OllamaHost.TrimEnd('/')) -ContentType 'application/json' -Body $bodyGen -TimeoutSec $timeout
      if ($resp) { Write-Info ("Ollama warmup (generate) OK for {0}" -f $Model); return $true }
    } catch { Write-Warn ("Warmup generate warning: {0}" -f $_.Exception.Message) }

    try {
      $msg = @{ role='user'; content=$prompt }
      if ($b64) { $msg.images = @($b64) }
      $bodyChat = @{ model = $Model; stream = $false; messages = @($msg) } | ConvertTo-Json -Depth 8
      $respC = Invoke-RestMethod -Method Post -Uri ("{0}/api/chat" -f $OllamaHost.TrimEnd('/')) -ContentType 'application/json' -Body $bodyChat -TimeoutSec $timeout
      if ($respC) { Write-Info ("Ollama warmup (chat) OK for {0}" -f $Model); return $true }
    } catch { Write-Warn ("Warmup chat warning: {0}" -f $_.Exception.Message) }
  } catch { Write-Warn ("Warmup error: {0}" -f $_.Exception.Message) }
  return $false
}

# ---- Ensure Ollama server is running (Windows-friendly) ----
function Test-OllamaReady {
  param([string]$OllamaHost)
  try {
    if (-not $OllamaHost -or [string]::IsNullOrWhiteSpace($OllamaHost)) { $OllamaHost = 'http://127.0.0.1:11434' }
    $uri = ($OllamaHost.TrimEnd('/')) + '/api/tags'
    $null = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 2
    return $true
  } catch { return $false }
}

function Ensure-OllamaServer {
  param([string]$OllamaHost)
  if (Test-OllamaReady -OllamaHost $OllamaHost) { Write-Info ("Ollama ready at {0}" -f $OllamaHost); return $true }

  # Try starting Windows service if installed
  $svc = $null
  try { $svc = Get-Service -Name 'Ollama' -ErrorAction SilentlyContinue } catch {}
  if ($svc -and $svc.Status -ne 'Running') {
    try { Start-Service -Name 'Ollama'; Write-Info 'Starting Ollama service...'; } catch { Write-Warn ("Ollama service start failed: {0}" -f $_.Exception.Message) }
  }
  for ($i=0; $i -lt 10; $i++) { if (Test-OllamaReady -OllamaHost $OllamaHost) { Write-Info 'Ollama is up (service).'; return $true }; Start-Sleep -Milliseconds 300 }

  # Try spawning the binary if service not available
  $candidates = @(
    [IO.Path]::Combine($env:LOCALAPPDATA,'Programs','Ollama','ollama.exe'),
    [IO.Path]::Combine($env:ProgramFiles,'Ollama','ollama.exe'),
    'C:\\Program Files\\Ollama\\ollama.exe'
  )
  foreach ($exe in $candidates) {
    if (Test-Path -LiteralPath $exe) {
      try {
        $p = Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden -PassThru
        Write-Info ("Started Ollama serve (PID {0}) via {1}" -f $p.Id, $exe)
      } catch { Write-Warn ("Could not start Ollama serve via {0}: {1}" -f $exe, $_.Exception.Message) }
      break
    }
  }
  for ($i=0; $i -lt 10; $i++) { if (Test-OllamaReady -OllamaHost $OllamaHost) { Write-Info 'Ollama is up (spawn).'; return $true }; Start-Sleep -Milliseconds 300 }

  Write-Warn ("Ollama not reachable at {0}; Vision captions will be empty until it is running." -f $OllamaHost)
  return $false
}

# ---- child script paths ----
$pathEcho    = Join-Home 'Start-Echo.ps1'
$pathIM      = Join-Home 'Start-IM.ps1'
$pathRoom    = Join-Home 'Start-EchoRoom.ps1'
$pathVision  = Join-Home 'Start-VisionProbe-Lite.ps1'
$pathWhisper = Join-Home 'tools\Start-WhisperStreamToInbox.ps1'

# ---- Start-Child (PS5.1-safe) ----
function Start-Child {
  param(
    [Parameter(Mandatory=$true)][string]$File,
    [string[]]$Args = @(),
    [string]$Name = '',
    [string]$WorkingDir = $env:ECHO_HOME
  )
  if (-not (Test-Path -LiteralPath $File)) {
    Write-Err ("Missing child script: {0}" -f $File)
    return $null
  }

  $ps7 = [IO.Path]::Combine($env:ProgramFiles,'PowerShell\7\pwsh.exe')
  if (Test-Path -LiteralPath $ps7) {
    $psExe = $ps7
  } else {
    $psExe = [IO.Path]::Combine($env:SystemRoot,'System32\WindowsPowerShell\v1.0\powershell.exe')
  }

  $argList = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $File)) + $Args
  $argJoined = [string]::Join(' ', $argList)

  try {
    $p = Start-Process -FilePath $psExe -ArgumentList $argJoined -WorkingDirectory $WorkingDir -WindowStyle Hidden -PassThru
    if ($Name -and $Name.Trim().Length -gt 0) {
      Write-Info ("Started {0} (PID {1})" -f $Name, $p.Id)
    } else {
      Write-Info ("Started: {0} (PID {1})" -f $File, $p.Id)
    }
    return $p
  } catch {
    $label = $File
    if ($Name -and $Name.Trim().Length -gt 0) { $label = $Name }
    Write-Err ("{0} failed: {1}" -f $label, $_.Exception.Message)
    return $null
  }
}

# ---- print plan ----
Write-Info "Using:"
Write-Info ("  Echo      : {0}" -f $pathEcho)
Write-Info ("  IM        : {0}" -f $pathIM)
Write-Info ("  EchoRoom  : {0}" -f $pathRoom)
Write-Info ("  VisionLite: {0}" -f $pathVision)
Write-Info ("  Whisper   : {0}" -f $pathWhisper)

# ---- launch children ----
# Ensure Ollama server is up before starting VisionLite (non-fatal if not)
[void](Ensure-OllamaServer -OllamaHost $env:OLLAMA_HOST)
# Warm up the vision model so short VisionLite timeouts succeed
[void](Warm-OllamaVision -OllamaHost $env:OLLAMA_HOST -Model $env:ECHO_VISION_MODEL)
$children = [ordered]@{}
$children['Echo']   = Start-Child -File $pathEcho  -Name 'Echo'
$children['IM']     = Start-Child -File $pathIM    -Name 'IM'
$children['Room']   = Start-Child -File $pathRoom  -Name 'EchoRoom'

# VisionLite args (Ollama + qwen2.5-vl:3b)
$children['Vision'] = Start-Child -File $pathVision -Name 'VisionLite' -Args @(
  '-Backend','ollama',
  '-Model',  ('"{0}"' -f $env:ECHO_VISION_MODEL),
  '-IntervalSec','8',
  '-KeepSec','60',
  '-OutJsonl', ('"{0}"' -f $env:ECHO_SCREEN_JSONL)
)

if (Test-Path -LiteralPath $pathWhisper) {
  $children['Whisper'] = Start-Child -File $pathWhisper -Name 'Whisper'
}

# ---- show PIDs (PS5.1-safe join) ----
$pidPairs = @()
foreach ($k in $children.Keys) {
  $proc = $children[$k]
  if ($proc -and $proc.Id) { $pidPairs += ("{0}={1}" -f $k, $proc.Id) }
}
if ($pidPairs.Count -gt 0) {
  Write-Info ("PIDs: {0}" -f ([string]::Join(', ', $pidPairs)))
} else {
  Write-Warn 'No children appear to be running.'
}

Write-Info "Done. Tail logs in .\logs (latest *.log files)."
