# Start Vision Model Server
# Runs llama-server with vision model loaded persistently

<#
    Start-VisionServer.ps1

    This script starts a multimodal Llama model server on a designated GPU.  It wraps
    `llama-server.exe` and provides sensible defaults while still allowing the
    caller to override the important bits via parameters or environment
    variables.  By exposing the model file, multimodal projector, alias,
    threading and batching options as parameters it becomes easier to
    experiment with different configurations without editing this file each
    time.  Use `--list-devices` with your compiled `llama-server.exe` to see
    which Vulkan devices correspond to your GPUs【783874784385917†L136-L139】.

    Environment variables can be used to override any of the parameters below.
    For example, set `LLAMA_SERVER_MODEL` to point at your gguf model file,
    `LLAMA_SERVER_MMPROJ` to override the projector path, or
    `LLAMA_SERVER_GPU` to select a different GPU index.  If you do not supply
    a value the defaults mirror the original behaviour (model and projector
    hard‑coded in D:\Echo\models, alias set to `vision`, and GPU index 1).
    Documentation for the underlying server options can be found in the
    llama.cpp repository【783874784385917†L314-L328】.
>
param(
    # HTTP port the server will listen on.  Default: 8082.  Can be set via
    # $env:LLAMA_SERVER_PORT.
    [int]$Port = (
        # Use LLAMA_SERVER_PORT if valid; otherwise fallback to default
        if ($env:LLAMA_SERVER_PORT -and [int]::TryParse($env:LLAMA_SERVER_PORT, [ref]([int]0))) {
            [int]$env:LLAMA_SERVER_PORT
        } else {
            8082
        }
    ),

    # Host/IP address to bind to.  Default: 127.0.0.1.  Can be set via
    # $env:LLAMA_SERVER_HOST.
    [string]$ListenHost = if ($env:LLAMA_SERVER_HOST -and $env:LLAMA_SERVER_HOST.Trim()) { $env:LLAMA_SERVER_HOST.Trim() } else { '127.0.0.1' },

    # Zero‑based GPU index to run the model on.  Use `llama-server.exe --list-devices`
    # to see available Vulkan devices【783874784385917†L136-L139】.  Default: 1.  Can be set via
    # $env:LLAMA_SERVER_GPU.
    [int]$Gpu = if ([int]::TryParse($env:LLAMA_SERVER_GPU, [ref]([int]0))) { [int]$env:LLAMA_SERVER_GPU } else { 1 },

    # Path to the GGUF model to load.  Default points at the Qwen vision model
    # included with Echo.  Can be set via $env:LLAMA_SERVER_MODEL.
    [string]$ModelPath = if ($env:LLAMA_SERVER_MODEL -and (Test-Path -LiteralPath $env:LLAMA_SERVER_MODEL)) {
        $env:LLAMA_SERVER_MODEL
    } else {
        'D:\Echo\models\thesby_Qwen2.5-VL-7B-NSFW-Caption-V3-Q3_K_XL.gguf'
    },

    # Path to the multimodal projector.  Default uses the Qwen projector.  Can be
    # set via $env:LLAMA_SERVER_MMPROJ.
    [string]$MMProjPath = if ($env:LLAMA_SERVER_MMPROJ -and (Test-Path -LiteralPath $env:LLAMA_SERVER_MMPROJ)) {
        $env:LLAMA_SERVER_MMPROJ
    } else {
        'D:\Echo\models\Qwen2.5-VL-7B-Abliterated-Caption-it.mmproj-Q8_0.gguf'
    },

    # Alias name returned via the OpenAI-compatible API.  Default: 'vision'.  Can
    # be set via $env:LLAMA_SERVER_ALIAS.  Note: this alias must match the
    # `model` parameter you supply from your client code.
    [string]$Alias = if ($env:LLAMA_SERVER_ALIAS -and $env:LLAMA_SERVER_ALIAS.Trim()) {
        $env:LLAMA_SERVER_ALIAS.Trim()
    } else {
        'vision'
    },

    # Number of layers to offload to the GPU.  999 offloads all available
    # layers.  You can override via $env:LLAMA_SERVER_NGL if a lower number
    # is desired for memory‑constrained GPUs.  Only relevant when using
    # GPU backends【783874784385917†L136-L156】.
    [int]$Ngl = if ([int]::TryParse($env:LLAMA_SERVER_NGL, [ref]([int]0))) { [int]$env:LLAMA_SERVER_NGL } else { 999 },

    # Context size to allocate (the prompt length in tokens).  Larger models may
    # require more context.  Default: 2056 (fits Qwen 7B vision on RX 580).
    [int]$CtxSize = if ([int]::TryParse($env:LLAMA_SERVER_CTX_SIZE, [ref]([int]0))) { [int]$env:LLAMA_SERVER_CTX_SIZE } else { 2056 },

    # Number of CPU threads to use.  Default: 4.  Can be set via
    # $env:LLAMA_SERVER_THREADS.
    [int]$Threads = if ([int]::TryParse($env:LLAMA_SERVER_THREADS, [ref]([int]0))) { [int]$env:LLAMA_SERVER_THREADS } else { 4 },

    # Logical batch size for prompt processing.  Default: 128.  Can be set via
    # $env:LLAMA_SERVER_BATCH.
    [int]$BatchSize = if ([int]::TryParse($env:LLAMA_SERVER_BATCH, [ref]([int]0))) { [int]$env:LLAMA_SERVER_BATCH } else { 128 },

    # Micro‑batch size for GPU offload.  Default: 32.  Can be set via
    # $env:LLAMA_SERVER_UBATCH.
    [int]$UbatchSize = if ([int]::TryParse($env:LLAMA_SERVER_UBATCH, [ref]([int]0))) { [int]$env:LLAMA_SERVER_UBATCH } else { 32 },

    # Skip model warmup.  Warmup runs a dummy pass to compile kernels and can
    # cause a memory spike on GPUs with limited VRAM.  Default: $true.  You can
    # disable warmup by specifying -NoWarmup:$false.
    [switch]$NoWarmup = $true,

    # Disable server logging.  Default: $true.  Use -LogDisable:$false to
    # preserve stdout/stderr from the underlying process.
    [switch]$LogDisable = $true
)

# Prefer a Vulkan-capable llama-server so we can run on the RX 580.
$ServerExe = 'D:\llama-cpp-vulkan\llama-server.exe'
if ($env:LLAMA_VISION_EXE -and (Test-Path -LiteralPath $env:LLAMA_VISION_EXE)) {
  $leaf = Split-Path -Leaf $env:LLAMA_VISION_EXE
  if ($leaf -match 'server') {
    $ServerExe = $env:LLAMA_VISION_EXE
  }
}
# Resolve model and projector from parameters
$Model = $ModelPath
$MMProj = $MMProjPath

Write-Host "Starting Vision Model Server..." -ForegroundColor Cyan
Write-Host "  Exe: $ServerExe" -ForegroundColor Gray
Write-Host "  Model: $Model" -ForegroundColor Gray
Write-Host "  MMProj: $MMProj" -ForegroundColor Gray
Write-Host "  Alias: $Alias" -ForegroundColor Gray
Write-Host "  GPU Index: $Gpu" -ForegroundColor Gray
Write-Host "  Context size: $CtxSize" -ForegroundColor Gray
Write-Host "  Batch size: $BatchSize, Micro-batch size: $UbatchSize" -ForegroundColor Gray
Write-Host "  NGL (GPU layers): $Ngl" -ForegroundColor Gray
Write-Host "  Listening on: http://${ListenHost}:${Port}" -ForegroundColor Gray
Write-Host ""

# Kill any existing vision server on this port
Get-Process llama-server -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "*$Port*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue

# Check files exist
if (-not (Test-Path $ServerExe)) {
    Write-Host "ERROR: llama-server.exe not found at: $ServerExe" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Model)) {
    Write-Host "ERROR: Model not found at: $Model" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $MMProj)) {
    Write-Host "ERROR: MMProj not found at: $MMProj" -ForegroundColor Red
    exit 1
}

# Build argument list for llama-server.  Only include flags when the
# corresponding switch is enabled.  Note: -kvu disables unified KV cache;
# this is often required to reduce memory footprint on GPUs with limited
# VRAM.  Adjust as needed.
$serverArgs = @(
    '-m', $Model,
    '--mmproj', $MMProj,
    '--alias', $Alias,
    '-ngl', $Ngl,
    '--device', ("Vulkan{0}" -f $Gpu),
    '--main-gpu', $Gpu,
    '-t', $Threads,
    '-c', $CtxSize,
    '-b', $BatchSize,
    '-ub', $UbatchSize,
    '-kvu',
    '-np', '1',
    '--host', $ListenHost,
    '--port', $Port
)

# Append warmup / logging switches depending on user selection
if ($NoWarmup.IsPresent) {
    $serverArgs += '--no-warmup'
}
if ($LogDisable.IsPresent) {
    $serverArgs += '--log-disable'
}

Write-Host "Launching server..." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop" -ForegroundColor Gray
Write-Host ""

& $ServerExe @serverArgs
