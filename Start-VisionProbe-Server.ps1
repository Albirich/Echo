# Start Vision Model Server
# Runs llama-server with vision model loaded persistently

param(
    [int]$Port = 8082,
    [string]$ListenHost = '127.0.0.1',
    [int]$Gpu = 1   # zero-based GPU index (1 = second GPU)
)

# Prefer a Vulkan-capable llama-server so we can run on the RX 580.
$ServerExe = 'D:\llama-cpp-vulkan\llama-server.exe'
if ($env:LLAMA_VISION_EXE -and (Test-Path -LiteralPath $env:LLAMA_VISION_EXE)) {
  $leaf = Split-Path -Leaf $env:LLAMA_VISION_EXE
  if ($leaf -match 'server') {
    $ServerExe = $env:LLAMA_VISION_EXE
  }
}
$Model = 'D:\Echo\models\thesby_Qwen2.5-VL-7B-NSFW-Caption-V3-Q3_K_XL.gguf'
$MMProj = 'D:\Echo\models\Qwen2.5-VL-7B-Abliterated-Caption-it.mmproj-Q8_0.gguf'

Write-Host "Starting Vision Model Server..." -ForegroundColor Cyan
Write-Host "  Exe: $ServerExe" -ForegroundColor Gray
Write-Host "  Model: $Model" -ForegroundColor Gray
Write-Host "  MMProj: $MMProj" -ForegroundColor Gray
Write-Host "  GPU Index: $Gpu" -ForegroundColor Gray
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

$serverArgs = @(
    '-m', $Model,
    '--mmproj', $MMProj,
    '--no-mmproj-offload',                  # Keep vision encoder on CPU (RX 580 Vulkan lacks fp16)
    '--alias', 'vision',                    # Name the model
    '-ngl', '999',                          # All layers to GPU
    '--device', ("Vulkan{0}" -f $Gpu),      # Select Radeon (GPU index)
    '--main-gpu', $Gpu,                     # Bind to second GPU (index 1)
    '-t', '4',                              # Threads
    '-c', '3596',                           # Context size (images need ~2700 tokens)
    '-b', '128',                            # Batch size
    '-ub', '32',                            # Micro-batch size
    '-np', '1',                             # Force 1 parallel slot
    '--host', $ListenHost,
    '--port', $Port,
    '--no-warmup',                          # Skip warmup to save memory spikes
    '--log-disable'
)

Write-Host "Launching server..." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop" -ForegroundColor Gray
Write-Host ""

& $ServerExe @serverArgs
