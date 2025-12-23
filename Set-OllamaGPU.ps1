<#
.SYNOPSIS
  Set system-level environment variables for Ollama GPU optimization

.DESCRIPTION
  If Ollama runs as a Windows Service, it uses SYSTEM environment variables
  instead of session variables. This script sets GPU optimization env vars
  at the user or machine level so the Ollama service can use them.

.PARAMETER Machine
  Set environment variables at machine level (requires admin).
  Default: User level only.

.EXAMPLE
  .\Set-OllamaGPU.ps1

.EXAMPLE
  .\Set-OllamaGPU.ps1 -Machine
#>

[CmdletBinding()]
param(
  [switch]$Machine
)

$env_vars = @{
  'OLLAMA_NUM_GPU' = '999'           # Offload all layers to GPU
  'OLLAMA_MAIN_GPU' = '0'            # Use first GPU
  'OLLAMA_NUM_THREAD' = '2'          # Minimal CPU threads
  'OLLAMA_NUM_PARALLEL' = '1'        # Single request queue
  'OLLAMA_MAX_LOADED_MODELS' = '1'   # One model at a time
  'OLLAMA_FLASH_ATTENTION' = '1'     # Enable flash attention
  'OLLAMA_NO_CPU_FALLBACK' = '1'     # Force GPU, no CPU fallback
}

$target = if ($Machine) { 'Machine' } else { 'User' }

Write-Host "Setting Ollama GPU environment variables at $target level..." -ForegroundColor Cyan
Write-Host ""

foreach ($key in $env_vars.Keys) {
  $value = $env_vars[$key]
  try {
    [Environment]::SetEnvironmentVariable($key, $value, $target)
    Write-Host "  [OK] $key = $value" -ForegroundColor Green
  } catch {
    Write-Host "  [FAIL] $key - $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host ""
Write-Host "Done! Restart Ollama service for changes to take effect:" -ForegroundColor Yellow
Write-Host "  Restart-Service -Name Ollama" -ForegroundColor White
Write-Host ""
Write-Host "Or restart Echo if using spawned Ollama binary." -ForegroundColor Yellow
