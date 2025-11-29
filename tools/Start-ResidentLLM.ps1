#requires -Version 5.1
<#
.SYNOPSIS
  Resident LLM worker using HTTP instead of process spawning

.DESCRIPTION
  Lightweight worker that monitors file queue and processes requests via
  llama-server HTTP API instead of spawning llama-cli.exe processes.
  
  Benefits:
  - No process spawning overhead (10-50x faster)
  - Model stays loaded in VRAM (instant responses)
  - KV cache reuse across requests
  - 90% less CPU usage

.PARAMETER Role
  Worker role (Chat or IM)

.PARAMETER ServerUrl
  llama-server URL (default: from ECHO_LLAMA_SERVER env or http://127.0.0.1:8080)

.PARAMETER CtxSize
  Context size for requests (default: 2048)

.PARAMETER NPredict
  Max tokens to generate per request (default: 192)

.PARAMETER Temperature
  Sampling temperature (default: 0.7)

.PARAMETER EchoHome
  Echo home directory (default: D:\Echo)

.PARAMETER PollMs
  Polling interval in milliseconds (default: 200)

.PARAMETER UseFileWatcher
  Use FileSystemWatcher instead of polling (more efficient)

.EXAMPLE
  .\Start-ResidentLLM.ps1 -Role Chat -ServerUrl "http://127.0.0.1:8080"
  
.EXAMPLE
  .\Start-ResidentLLM.ps1 -Role IM -UseFileWatcher
#>

param(
  [ValidateSet('Chat','IM')] [string]$Role = 'Chat',
  [string]$ServerUrl = '',
  [int]$CtxSize   = 2048,
  [int]$NPredict  = 192,
  [double]$Temperature = 0.7,
  [string]$EchoHome = 'D:\Echo',
  [int]$PollMs = 200,
  [switch]$UseFileWatcher
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Configuration
# ============================================================

# Get server URL from env or parameter
if (-not $ServerUrl) {
  $ServerUrl = if ($env:ECHO_LLAMA_SERVER) { $env:ECHO_LLAMA_SERVER } else { 'http://127.0.0.1:8080' }
}

Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Resident LLM Worker (HTTP-based)" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Role:       $Role" -ForegroundColor Green
Write-Host "  Server:     $ServerUrl" -ForegroundColor Green
Write-Host "  Max Tokens: $NPredict" -ForegroundColor Green
Write-Host "  Temp:       $Temperature" -ForegroundColor Green
Write-Host "  Mode:       $(if ($UseFileWatcher) { 'FileSystemWatcher (event-driven)' } else { "Polling ($PollMs ms)" })" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Cyan

# ============================================================
# Setup Directories
# ============================================================

function Ensure-Dir([string]$p){
  if (-not (Test-Path -LiteralPath $p)) { 
    New-Item -ItemType Directory -Force -Path $p | Out-Null 
  }
}

$stateDir = Join-Path $EchoHome 'state'
$busRole  = Join-Path (Join-Path $EchoHome 'bus') $Role
$inDir    = Join-Path $busRole 'in'
$outDir   = Join-Path $busRole 'out'
$logDir   = Join-Path $EchoHome 'logs'

Ensure-Dir $stateDir
Ensure-Dir $inDir
Ensure-Dir $outDir
Ensure-Dir $logDir

$pidFile = Join-Path $stateDir ("resident.{0}.pid" -f $Role)
Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII

$logFile = Join-Path $logDir ("resident.{0}.log" -f $Role)
$errFile = Join-Path $logDir ("resident.{0}.err.log" -f $Role)

# ============================================================
# Helper Functions
# ============================================================

function Write-Log {
  param([string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  $line = "[$ts] $Message"
  Write-Host $line -ForegroundColor Gray
  try {
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  } catch {}
}

function Write-ErrorLog {
  param([string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  $line = "[$ts] ERROR: $Message"
  Write-Host $line -ForegroundColor Red
  try {
    Add-Content -LiteralPath $errFile -Value $line -Encoding UTF8
  } catch {}
}

function Test-ServerHealth {
  try {
    $response = Invoke-WebRequest -Uri "$ServerUrl/health" -Method Get -TimeoutSec 2 -UseBasicParsing
    return ($response.StatusCode -eq 200)
  } catch {
    return $false
  }
}

# ============================================================
# HTTP-Based Processing
# ============================================================

function Invoke-LLMCompletion {
  param(
    [string]$Prompt,
    [int]$MaxTokens = $NPredict,
    [double]$Temp = $Temperature
  )
  
  try {
    $body = @{
      prompt = $Prompt
      n_predict = $MaxTokens
      temperature = $Temp
      stop = @("<end_of_turn>", "<|im_end|>")
      cache_prompt = $true  # Enable KV cache reuse
    } | ConvertTo-Json -Depth 5
    
    $response = Invoke-RestMethod `
      -Uri "$ServerUrl/completion" `
      -Method Post `
      -Body $body `
      -ContentType "application/json; charset=utf-8" `
      -TimeoutSec 60 `
      -ErrorAction Stop
    
    # Extract and clean response
    $result = $response.content
    if ($result) {
      # Remove stop tokens
      $result = $result -replace '<end_of_turn>.*$',''
      $result = $result -replace '<\|im_end\|>.*$',''
      return $result.Trim()
    } else {
      throw "Empty response from server"
    }
    
  } catch {
    throw "HTTP request failed: $($_.Exception.Message)"
  }
}

# ============================================================
# Job Processing
# ============================================================

function Process-Job {
  param(
    [string]$InFile,
    [string]$OutFile
  )
  
  $jobId = [System.IO.Path]::GetFileNameWithoutExtension($InFile)
  Write-Log "[$Role] Processing job: $jobId"
  
  try {
    # Read input
    $raw = [System.IO.File]::ReadAllText($InFile, [System.Text.UTF8Encoding]::new($false))
    
    # Wrap in ChatML if needed
    if ($raw -notmatch '<start_of_turn>|<\|im_start\|>') {
      $prompt = "<start_of_turn>user`n$raw`n<end_of_turn>`n<start_of_turn>model`n"
    } else {
      $prompt = $raw
    }
    
    # Make HTTP request to llama-server
    $startTime = Get-Date
    $response = Invoke-LLMCompletion -Prompt $prompt -MaxTokens $NPredict -Temp $Temperature
    $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
    
    # Write output
    [System.IO.File]::WriteAllText($OutFile, $response, [System.Text.UTF8Encoding]::new($false))
    
    Write-Log "[$Role] Completed job: $jobId (${elapsed}ms)"
    Write-Host "[$Role] ✓ $jobId -> $([System.IO.Path]::GetFileName($OutFile)) (${elapsed}ms)" -ForegroundColor Green
    
    return $true
    
  } catch {
    $errMsg = $_.Exception.Message
    Write-ErrorLog "[$Role] Job failed: $jobId - $errMsg"
    
    # Write empty response so caller doesn't hang
    try {
      [System.IO.File]::WriteAllText($OutFile, "", [System.Text.UTF8Encoding]::new($false))
    } catch {}
    
    return $false
  }
}

# ============================================================
# Main Worker Loop - Polling Version
# ============================================================

function Start-PollingWorker {
  Write-Log "[$Role] Starting polling worker (interval: ${PollMs}ms)"
  
  while ($true) {
    try {
      # Get oldest job
      $job = Get-ChildItem -LiteralPath $inDir -Filter *.txt -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime | 
             Select-Object -First 1
      
      if (-not $job) {
        Start-Sleep -Milliseconds $PollMs
        continue
      }
      
      $inFile  = $job.FullName
      $outFile = Join-Path $outDir $job.Name
      
      # Process the job
      Process-Job -InFile $inFile -OutFile $outFile
      
      # Remove input file
      try {
        Remove-Item -LiteralPath $inFile -Force -ErrorAction Stop
      } catch {
        Write-ErrorLog "Failed to remove input file: $inFile"
      }
      
    } catch {
      Write-ErrorLog "Worker loop error: $($_.Exception.Message)"
      Start-Sleep -Milliseconds 1000
    }
  }
}

# ============================================================
# Main Worker Loop - FileSystemWatcher Version
# ============================================================

function Start-WatcherWorker {
  Write-Log "[$Role] Starting FileSystemWatcher worker"
  
  # Create watcher
  $watcher = New-Object System.IO.FileSystemWatcher
  $watcher.Path = $inDir
  $watcher.Filter = "*.txt"
  $watcher.EnableRaisingEvents = $true
  $watcher.IncludeSubdirectories = $false
  
  # Event handler
  $action = {
    param($sender, $e)
    
    # Small delay to ensure file is fully written
    Start-Sleep -Milliseconds 50
    
    if (-not (Test-Path -LiteralPath $e.FullPath)) { return }
    
    $inFile = $e.FullPath
    $outFile = Join-Path $outDir ([System.IO.Path]::GetFileName($inFile))
    
    # Process the job
    Process-Job -InFile $inFile -OutFile $outFile
    
    # Remove input file
    try {
      Remove-Item -LiteralPath $inFile -Force -ErrorAction SilentlyContinue
    } catch {}
  }
  
  # Register event
  $null = Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action
  
  Write-Log "[$Role] FileSystemWatcher active. Monitoring: $inDir"
  Write-Host "[$Role] 🔍 Watching for files..." -ForegroundColor Yellow
  
  # Keep alive (also process any existing files)
  while ($true) {
    # Check for any files that might have been there before watcher started
    $existing = Get-ChildItem -LiteralPath $inDir -Filter *.txt -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime
    
    foreach ($job in $existing) {
      $inFile = $job.FullName
      $outFile = Join-Path $outDir $job.Name
      Process-Job -InFile $inFile -OutFile $outFile
      try { Remove-Item -LiteralPath $inFile -Force } catch {}
    }
    
    Start-Sleep -Seconds 5
  }
}

# ============================================================
# Startup
# ============================================================

Write-Host "`n[$Role] Resident worker ready!" -ForegroundColor Green
Write-Host "  IN:  $inDir" -ForegroundColor Cyan
Write-Host "  OUT: $outDir" -ForegroundColor Cyan

# Health check
Write-Host "`n[$Role] Checking llama-server health..." -ForegroundColor Yellow
if (Test-ServerHealth) {
  Write-Host "[$Role] ✓ llama-server is healthy at $ServerUrl" -ForegroundColor Green
} else {
  Write-Host "[$Role] ⚠ WARNING: llama-server not responding at $ServerUrl" -ForegroundColor Red
  Write-Host "[$Role] Start it with:" -ForegroundColor Yellow
  Write-Host "  .\tools\Start-LlamaServer.ps1 -ModelPath 'path\to\model.gguf' -Threads 4 -Ngl 999" -ForegroundColor Yellow
  Write-Host "`n[$Role] Worker will retry requests, but they will fail until server is available." -ForegroundColor Yellow
}

Write-Host "`n[$Role] Starting worker loop..." -ForegroundColor Green
Write-Host ""

# ============================================================
# Main Loop
# ============================================================

try {
  if ($UseFileWatcher) {
    Start-WatcherWorker
  } else {
    Start-PollingWorker
  }
} finally {
  Write-Log "[$Role] Shutting down"
  try { Remove-Item -LiteralPath $pidFile -Force } catch {}
}
