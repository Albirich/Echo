param(
  [Parameter(Mandatory=$true)][string]$PromptFile,
  [string]$ModelPath = "",  # Not used in HTTP mode, kept for compatibility
  [string]$LlamaExe  = "",  # Not used in HTTP mode, kept for compatibility
  [string]$ServerUrl = "",
  [int]$CtxSize      = 4096,
  [int]$GpuLayers    = 999,  # Not used in HTTP mode
  [int]$MaxTokens    = 1024,
  [double]$Temp      = 0.7,
  [switch]$FlashAttn,        # Not used in HTTP mode
  [string[]]$Images,
  [string]$Mmproj,           # Not used in HTTP mode
  [switch]$JsonOut
)

$ErrorActionPreference = "Stop"

# ============================================================
# HTTP-Based LLM Execution (NO PROCESS SPAWNING!)
# ============================================================
# This version uses llama-server HTTP API instead of spawning llama-cli.exe
# Benefits: 10-50x faster, no model reloading, KV cache reuse, 90% less CPU

$ECHO  = if ($env:ECHO_HOME -and (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME } else { "D:\Echo" }
$Logs  = Join-Path $ECHO "logs"; New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$Outbx = Join-Path $ECHO "ui\outbox.jsonl"; if (!(Test-Path $Outbx)) { New-Item -ItemType File -Force -Path $Outbx | Out-Null }

$ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss_fff"
$logF = Join-Path $Logs "llama-http-$ts-$PID.log"

# Get server URL
if (-not $ServerUrl) {
  $ServerUrl = if ($env:ECHO_LLAMA_SERVER) { $env:ECHO_LLAMA_SERVER } else { "http://127.0.0.1:8080" }
}

# Read prompt file
try {
  $promptText = [System.IO.File]::ReadAllText($PromptFile, [System.Text.UTF8Encoding]::new($false))
} catch {
  $promptText = Get-Content -Raw $PromptFile -Encoding UTF8
}

$hdr = @"
==== llama-server HTTP REQUEST ====
Time:        $ts
Server:      $ServerUrl
Max tokens:  $MaxTokens
Temp:        $Temp
PromptFile:  $PromptFile
JsonOut:     $JsonOut
Log:         $logF
===================================
"@
[IO.File]::WriteAllText($logF, $hdr, [Text.UTF8Encoding]::new($false))

# ============================================================
# Handle Vision (Images)
# ============================================================
$imageData = @()
if ($Images -and $Images.Count -gt 0) {
  foreach ($imgPath in $Images) {
    if (Test-Path -LiteralPath $imgPath) {
      try {
        # Convert image to base64
        $bytes = [System.IO.File]::ReadAllBytes($imgPath)
        $base64 = [Convert]::ToBase64String($bytes)
        
        # Detect image type
        $ext = [System.IO.Path]::GetExtension($imgPath).ToLower()
        $mimeType = switch ($ext) {
          '.jpg'  { 'image/jpeg' }
          '.jpeg' { 'image/jpeg' }
          '.png'  { 'image/png' }
          '.gif'  { 'image/gif' }
          '.webp' { 'image/webp' }
          default { 'image/jpeg' }
        }
        
        $imageData += @{
          data = $base64
          id = $imageData.Count
        }
        
        "Added image: $imgPath ($mimeType)" | Add-Content -LiteralPath $logF -Encoding UTF8
      } catch {
        "Failed to load image: $imgPath - $($_.Exception.Message)" | Add-Content -LiteralPath $logF -Encoding UTF8
      }
    }
  }
}

# ============================================================
# Build Request Body
# ============================================================
# Choose stop tokens based on prompt/model style
$stops = @("<|im_end|>", "<end_of_turn>")
try {
  $modelPath = $env:ECHO_LLAMACPP_MODEL
  if (($modelPath -and ($modelPath -match '(?i)mistral')) -or ($promptText -match '\[INST\]')) {
    # Stop when model tries to start another user turn
    $stops = @("[INST]", "</s>")
  }
} catch {}

$body = @{
  prompt = $promptText
  n_predict = $MaxTokens
  temperature = $Temp
  stop = $stops
  cache_prompt = $true
}

# Add image data if present
if ($imageData.Count -gt 0) {
  $body.image_data = $imageData
}

# JSON mode handling
if ($JsonOut) {
  $body.grammar = 'json'
  # No chat templating for JSON
  $body.add_bos_token = $false
}

$bodyJson = ($body | ConvertTo-Json -Depth 10)
$bodyJson | Add-Content -LiteralPath $logF -Encoding UTF8

# ============================================================
# Make HTTP Request
# ============================================================
$startTime = Get-Date
$raw = ""
$exit = 0

try {
  "Making HTTP POST to: $ServerUrl/completion" | Add-Content -LiteralPath $logF -Encoding UTF8
  
  $response = Invoke-RestMethod `
    -Uri "$ServerUrl/completion" `
    -Method Post `
    -Body $bodyJson `
    -ContentType "application/json; charset=utf-8" `
    -TimeoutSec 120 `
    -ErrorAction Stop
  
  $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
  "Response received in ${elapsed}ms" | Add-Content -LiteralPath $logF -Encoding UTF8
  
  $raw = $response.content
  
  # Log response metadata
  if ($response.PSObject.Properties['timings']) {
    $timings = $response.timings
    "Timings: prompt_ms=$($timings.prompt_ms) predicted_ms=$($timings.predicted_ms)" | Add-Content -LiteralPath $logF -Encoding UTF8
  }
  
  $exit = 0
  
} catch {
  $errMsg = $_.Exception.Message
  "ERROR: HTTP request failed: $errMsg" | Add-Content -LiteralPath $logF -Encoding UTF8
  
  # Check if server is running
  try {
    $health = Invoke-WebRequest -Uri "$ServerUrl/health" -Method Get -TimeoutSec 2 -UseBasicParsing
    if ($health.StatusCode -eq 200) {
      "Server is running but request failed" | Add-Content -LiteralPath $logF -Encoding UTF8
    }
  } catch {
    @"
ERROR: llama-server is not responding at $ServerUrl

Start it with:
  .\tools\Start-LlamaServer.ps1 -ModelPath "path\to\model.gguf" -Threads 4 -Ngl 999
"@ | Add-Content -LiteralPath $logF -Encoding UTF8
  }
  
  $raw = "ERROR: $errMsg"
  $exit = 1
}

"---- HTTP EXIT: $exit ----" | Add-Content -LiteralPath $logF -Encoding UTF8

# ============================================================
# Clean Output
# ============================================================
$clean = ($raw -replace "\r\n?","`n")

# Strip ChatML tags if present
$assistantTag = '<|im_start|>assistant'
$idx = $clean.LastIndexOf($assistantTag)
if ($idx -ge 0) {
  $clean = $clean.Substring($idx + $assistantTag.Length)
  if ($clean.StartsWith("`n")) { $clean = $clean.Substring(1) }
}

$endTag = '<|im_end|>'
$endIdx = $clean.IndexOf($endTag)
if ($endIdx -ge 0) { $clean = $clean.Substring(0, $endIdx) }

# Strip Gemma tags
$clean = $clean -replace '<start_of_turn>.*?<end_of_turn>',''
$clean = $clean -replace '<end_of_turn>.*$',''

$clean = $clean.Trim()

# ============================================================
# Log to Outbox JSONL
# ============================================================
$rec = [ordered]@{
  ts     = (Get-Date).ToString("o")
  source = "llama-server-http"
  model  = "via-http"
  ctx    = $CtxSize
  gpu    = $GpuLayers
  temp   = $Temp
  log    = $logF
  input  = $PromptFile
  prompt = $promptText
  prompt_len = ($promptText.Length)
  args   = "http-mode"
  exit_code = $exit
  text   = $clean
  gpu_backend = "cuda"
  gpu_used = $true
  server_url = $ServerUrl
}

function Add-JsonlSafe([string]$Path,[string]$Line,[int]$Retries=3){
  if ($Line -and $Line.Length -gt 0 -and [int][char]$Line[0] -eq 0xFEFF) {
    $Line = $Line.Substring(1)
  }
  $attempt = 0
  while ($attempt -le $Retries) {
    try {
      $sw = New-Object IO.StreamWriter($Path, $true, [Text.UTF8Encoding]::new($false))
      try { $sw.WriteLine($Line) } finally { $sw.Dispose() }
      return
    } catch {
      Start-Sleep -Milliseconds 50
      $attempt++
    }
  }
}

$line = ($rec | ConvertTo-Json -Compress -Depth 5)
Add-JsonlSafe -Path $Outbx -Line $line

# Debug snapshot
try {
  $dbgDir = Join-Path $ECHO 'debug'
  if (-not (Test-Path $dbgDir)) { New-Item -ItemType Directory -Force -Path $dbgDir | Out-Null }
  [IO.File]::WriteAllText((Join-Path $dbgDir 'last-llama.json'), ($rec | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
} catch {}

# Output cleaned text to STDOUT
Write-Output $clean
