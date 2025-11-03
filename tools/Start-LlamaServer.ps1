[CmdletBinding()]
param(
  [string]$ModelPath,
  [string]$BindHost = '127.0.0.1',
  [int]$Port = 8080,
  [string]$Alias = 'echo',
  [string]$LlamaServerExe,
  [int]$CtxSize = 2048,
  [int]$GpuLayers = 24,
  [int]$Threads = 3,
  [int]$Batch = 512,
  [int]$UBatch = 128
)

$ErrorActionPreference = 'Stop'

function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function IsoNow { (Get-Date).ToString('o') }

# Resolve Echo home
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$EchoHome = if ($env:ECHO_HOME -and (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME } else { Split-Path -Parent $ScriptRoot }
Set-Location $EchoHome

$state = Join-Path $EchoHome 'state'
$logs  = Join-Path $EchoHome 'logs'
Ensure-Dir $state; Ensure-Dir $logs

# Resolve llama-server path
if (-not $LlamaServerExe -or -not (Test-Path -LiteralPath $LlamaServerExe)) {
  $cand = 'D:\\llama-cpp\\llama-server.exe'
  if (Test-Path -LiteralPath $cand) { $LlamaServerExe = $cand }
}
if (-not (Test-Path -LiteralPath $LlamaServerExe)) { throw "llama-server.exe not found (set -LlamaServerExe or LLAMA_SERVER_EXE)" }

# Pick model path: explicit, env, or best gguf under models
if (-not $ModelPath -or -not (Test-Path -LiteralPath $ModelPath)) {
  try { if ($env:ECHO_LLAMACPP_MODEL -and (Test-Path $env:ECHO_LLAMACPP_MODEL)) { $ModelPath = $env:ECHO_LLAMACPP_MODEL } } catch {}
}
if (-not $ModelPath -or -not (Test-Path -LiteralPath $ModelPath)) {
  $modelsDir = Join-Path $EchoHome 'models'
  $cand = $null
  if (Test-Path -LiteralPath $modelsDir) {
    $cand = Get-ChildItem -LiteralPath $modelsDir -Filter *.gguf -File -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
  }
  if ($cand) { $ModelPath = $cand.FullName }
}
if (-not (Test-Path -LiteralPath $ModelPath)) { throw "Model not found: $ModelPath" }

# Optional overrides from env
try { if ($env:ECHO_LLAMA_THREADS -and $env:ECHO_LLAMA_THREADS.Trim()) { $Threads = [int]$env:ECHO_LLAMA_THREADS } } catch {}
try { if ($env:ECHO_LLAMA_CTX -and $env:ECHO_LLAMA_CTX.Trim())       { $CtxSize = [int]$env:ECHO_LLAMA_CTX } } catch {}
try { if ($env:ECHO_LLAMA_BATCH -and $env:ECHO_LLAMA_BATCH.Trim())   { $Batch   = [int]$env:ECHO_LLAMA_BATCH } } catch {}
try { if ($env:ECHO_LLAMA_UBATCH -and $env:ECHO_LLAMA_UBATCH.Trim()) { $UBatch  = [int]$env:ECHO_LLAMA_UBATCH } } catch {}
try { if ($env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { $GpuLayers = [int]$env:ECHO_LLAMA_GPU_LAYERS } } catch {}

# Build args
$args = @(
  '--host', $BindHost,
  '--port', $Port,
  '-m',     $ModelPath,
  '--alias', $Alias,
  '--ctx-size', $CtxSize,
  '--n-gpu-layers', $GpuLayers,
  '--batch-size', $Batch,
  '--ubatch-size', $UBatch,
  '--no-perf'
)
if ($Threads -gt 0) { $args += @('-t', $Threads) }

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$out = Join-Path $logs ("llama-server-${ts}.out.log")
$err = Join-Path $logs ("llama-server-${ts}.err.log")

Write-Host ("[llama-server] Starting on http://{0}:{1} with model: {2}" -f $Host,$Port,(Split-Path -Leaf $ModelPath))

$psi = @{
  FilePath               = $LlamaServerExe
  ArgumentList           = $args
  WorkingDirectory       = $EchoHome
  RedirectStandardOutput = $out
  RedirectStandardError  = $err
  WindowStyle            = 'Hidden'
  PassThru               = $true
}
$p = Start-Process @psi

# Record PID files so Stop-Echo can find them
[IO.File]::WriteAllText((Join-Path $state 'llama-server.launcher.pid'), [string]$PID)
[IO.File]::WriteAllText((Join-Path $state 'llama-server.pid'), [string]$p.Id)

# Wait until reachable
function Test-Reachable { param([string]$Base)
  try {
    Invoke-RestMethod -Uri ($Base.TrimEnd('/') + '/v1/models') -Method Get -TimeoutSec 2 | Out-Null
    return $true
  } catch { return $false }
}

$base = ("http://{0}:{1}" -f $BindHost, $Port)
for ($i=0; $i -lt 40; $i++) { if (Test-Reachable $base) { break }; Start-Sleep -Milliseconds 250 }
if (Test-Reachable $base) {
  Write-Host ("[llama-server] Ready at {0}" -f $base)
} else {
  Write-Warning ("[llama-server] Timed out waiting for readiness at {0}" -f $base)
}

# Keep this script alive while the child runs so Start-Child can track it
try {
  Wait-Process -Id $p.Id
} finally {
  try { Remove-Item -LiteralPath (Join-Path $state 'llama-server.pid') -Force } catch {}
}
