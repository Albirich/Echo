# Drop-in HTTP-based replacements for Echo
# Save this file and dot-source it in Start-Echo.ps1

# ============================================================
# HTTP-Based Send-ResidentLLM (replaces file-based version)
# ============================================================

function Send-ResidentLLM {
  <#
  .SYNOPSIS
    Send a prompt to the resident LLM using HTTP instead of file-based IPC
  
  .DESCRIPTION
    This is a drop-in replacement for the original Send-ResidentLLM function.
    Instead of writing to files and polling, it uses llama-server's HTTP API
    for instant responses with KV cache reuse.
  
  .PARAMETER Role
    The role (Chat or IM) - kept for compatibility but not used in HTTP version
  
  .PARAMETER Text
    The prompt text to send to the LLM
  
  .PARAMETER TimeoutSec
    Request timeout in seconds (default: 120)
  
  .PARAMETER EchoHome
    Echo home directory (default: from Get-EchoHome)
  
  .EXAMPLE
    Send-ResidentLLM -Role 'Chat' -Text 'Hello, how are you?'
  #>
  
  param(
    [ValidateSet('Chat','IM')] [string]$Role = 'Chat',
    [Parameter(Mandatory)] [string]$Text,
    [int]$TimeoutSec = 120,
    [string]$EchoHome = (Get-EchoHome)
  )
  
  # Get server URL from environment or use default
  $serverUrl = if ($env:ECHO_LLAMA_SERVER) { 
    $env:ECHO_LLAMA_SERVER 
  } else { 
    "http://127.0.0.1:8080" 
  }
  
  # Construct ChatML prompt
  $prompt = "<|im_start|>user`n$Text<|im_end|>`n<|im_start|>assistant`n"
  
  # Build request body
  $body = @{
    prompt = $prompt
    n_predict = 192
    temperature = 0.7
    stop = @("<|im_end|>")
    cache_prompt = $true  # Enable KV cache reuse
  } | ConvertTo-Json -Depth 5
  
  try {
    # Make HTTP request to llama-server
    $response = Invoke-RestMethod `
      -Uri "$serverUrl/completion" `
      -Method Post `
      -Body $body `
      -ContentType "application/json; charset=utf-8" `
      -TimeoutSec $TimeoutSec `
      -ErrorAction Stop
    
    # Extract and clean response
    $result = $response.content
    if ($result) {
      # Remove any trailing stop tokens
      $result = $result -replace '<\|im_end\|>.*$',''
      return $result.Trim()
    } else {
      throw "Empty response from server"
    }
    
  } catch {
    $errMsg = $_.Exception.Message
    Write-Warning "HTTP request to llama-server failed: $errMsg"
    
    # Check if server is running
    try {
      $healthCheck = Invoke-WebRequest -Uri "$serverUrl/health" -Method Get -TimeoutSec 2
      Write-Warning "Server is running but request failed. Check logs."
    } catch {
      Write-Error @"
llama-server is not running or not accessible at $serverUrl

Start it with:
  .\tools\Start-LlamaServer.ps1 -ModelPath "path\to\model.gguf" -Threads 4 -Ngl 999

Or set ECHO_LLAMA_SERVER environment variable to correct URL.
"@
    }
    
    throw "Resident $Role request failed: $errMsg"
  }
}

# ============================================================
# HTTP-Based Should-Interrupt (replaces process-spawning version)
# ============================================================

function Should-Interrupt {
  <#
  .SYNOPSIS
    Lightweight interrupt router using HTTP instead of spawning processes
  
  .DESCRIPTION
    Determines if a new user message should interrupt the current agentic loop.
    Uses llama-server HTTP API instead of spawning llama-cli.exe
  
  .PARAMETER UserText
    The new user message to evaluate
  
  .PARAMETER Model
    Model name (kept for compatibility)
  
  .PARAMETER TimeoutSec
    Request timeout in seconds
  
  .EXAMPLE
    $decision = Should-Interrupt -UserText "Stop what you're doing!" -Model "router"
  #>
  
  param(
    [Parameter(Mandatory=$true)][string]$UserText,
    [Parameter(Mandatory=$true)][string]$Model,
    [int]$TimeoutSec = 12
  )
  
  try {
    # System prompt for routing decision
    $sys = @'
Return ONLY valid JSON with exactly these keys:
{"interrupt":true|false,"reason":"short phrase","route":"quick|defer|cancel","priority":0..1}
Rules:
- "quick" if a one-line answer/no tools is enough (e.g., greeting, quick fact, small talk)
- "defer" if current agentic loop should continue and we can reply later
- "cancel" if the new message invalidates the running plan
- Be conservative: prefer defer unless clearly urgent or trivial.
'@
    
    $prompt = "<|im_start|>system`n$sys<|im_end|>`n<|im_start|>user`n$UserText<|im_end|>`n<|im_start|>assistant`n"
    
    # Get server URL
    $serverUrl = if ($env:ECHO_LLAMA_SERVER) { $env:ECHO_LLAMA_SERVER } else { "http://127.0.0.1:8080" }
    
    # Build request
    $body = @{
      prompt = $prompt
      n_predict = 120
      temperature = 0.2
      stop = @("<|im_end|>")
    } | ConvertTo-Json -Depth 5
    
    # Make request
    $response = Invoke-RestMethod `
      -Uri "$serverUrl/completion" `
      -Method Post `
      -Body $body `
      -ContentType "application/json" `
      -TimeoutSec $TimeoutSec
    
    # Clean and parse response
    $raw = $response.content
    $clean = ($raw -replace '```json','' -replace '```','').Trim()
    
    # Optional: Log the router decision
    try {
      if ($env:ECHO_HOME) {
        $logsDir = Join-Path $env:ECHO_HOME 'logs'
        if (Test-Path $logsDir) {
          $logFile = Join-Path $logsDir "router-$(Get-Date -Format 'yyyyMMdd').jsonl"
          $logEntry = @{
            ts = (Get-Date).ToString('o')
            input = $UserText
            output = $clean
          } | ConvertTo-Json -Compress
          Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
        }
      }
    } catch {}
    
    # Parse JSON response
    try {
      return ($clean | ConvertFrom-Json)
    } catch {
      Write-Warning "Failed to parse router response: $clean"
      return @{ interrupt=$false; reason='parse_fail'; route='defer'; priority=0.0 }
    }
    
  } catch {
    Write-Warning "Interrupt routing failed: $($_.Exception.Message)"
    return @{ interrupt=$false; reason='error'; route='defer'; priority=0.0 }
  }
}

# ============================================================
# Helper: Invoke-LLM (generic HTTP completion)
# ============================================================

function Invoke-LLM {
  <#
  .SYNOPSIS
    Generic function to call llama-server for any completion
  
  .DESCRIPTION
    Flexible function to make HTTP requests to llama-server with custom parameters
  
  .PARAMETER Prompt
    The prompt text or ChatML-formatted prompt
  
  .PARAMETER MaxTokens
    Maximum tokens to generate (default: 256)
  
  .PARAMETER Temperature
    Sampling temperature (default: 0.7)
  
  .PARAMETER Stop
    Stop sequences (default: "<|im_end|>")
  
  .PARAMETER CachePrompt
    Enable prompt caching for KV cache reuse (default: true)
  
  .PARAMETER Stream
    Enable streaming response (not yet implemented)
  
  .EXAMPLE
    $result = Invoke-LLM -Prompt "Explain quantum computing in one sentence" -MaxTokens 50
  #>
  
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [int]$MaxTokens = 256,
    [double]$Temperature = 0.7,
    [string[]]$Stop = @("<|im_end|>"),
    [bool]$CachePrompt = $true,
    [switch]$Stream
  )
  
  $serverUrl = if ($env:ECHO_LLAMA_SERVER) { $env:ECHO_LLAMA_SERVER } else { "http://127.0.0.1:8080" }
  
  $body = @{
    prompt = $Prompt
    n_predict = $MaxTokens
    temperature = $Temperature
    stop = $Stop
    cache_prompt = $CachePrompt
  } | ConvertTo-Json -Depth 5
  
  try {
    $response = Invoke-RestMethod `
      -Uri "$serverUrl/completion" `
      -Method Post `
      -Body $body `
      -ContentType "application/json" `
      -ErrorAction Stop
    
    return $response.content.Trim()
  } catch {
    Write-Error "LLM request failed: $($_.Exception.Message)"
    throw
  }
}

# ============================================================
# Helper: Test-LlamaServerHealth
# ============================================================

function Test-LlamaServerHealth {
  <#
  .SYNOPSIS
    Check if llama-server is running and healthy
  
  .DESCRIPTION
    Pings the /health endpoint to verify server availability
  
  .PARAMETER ServerUrl
    Server URL (default: from ECHO_LLAMA_SERVER or http://127.0.0.1:8080)
  
  .EXAMPLE
    if (Test-LlamaServerHealth) { Write-Host "Server is healthy" }
  #>
  
  param(
    [string]$ServerUrl = $(if ($env:ECHO_LLAMA_SERVER) { $env:ECHO_LLAMA_SERVER } else { "http://127.0.0.1:8080" })
  )
  
  try {
    $response = Invoke-WebRequest -Uri "$ServerUrl/health" -Method Get -TimeoutSec 2 -UseBasicParsing
    if ($response.StatusCode -eq 200) {
      Write-Host "✓ llama-server is healthy at $ServerUrl" -ForegroundColor Green
      return $true
    }
  } catch {
    Write-Warning "llama-server is not responding at $ServerUrl"
    Write-Host "Start it with: .\tools\Start-LlamaServer.ps1 -ModelPath 'path\to\model.gguf' -Threads 4 -Ngl 999" -ForegroundColor Yellow
    return $false
  }
}

# ============================================================
# Usage Examples
# ============================================================

<#

# 1. Test server health first
Test-LlamaServerHealth

# 2. Simple completion
$response = Send-ResidentLLM -Role 'Chat' -Text 'What is the capital of France?'
Write-Host $response

# 3. Interrupt routing
$decision = Should-Interrupt -UserText 'Hey, stop what you are doing!' -Model 'router'
if ($decision.interrupt) {
    Write-Host "Interrupt: $($decision.reason) - Route: $($decision.route)"
}

# 4. Generic LLM call
$result = Invoke-LLM -Prompt 'List 3 colors' -MaxTokens 50 -Temperature 0.5
Write-Host $result

#>

# ============================================================
# Integration Instructions
# ============================================================

<#

To integrate into Start-Echo.ps1:

1. Save this file as: D:\Echo\tools\EchoHTTP.psm1

2. In Start-Echo.ps1, add near the top (after line 62):
   
   try {
     Import-Module (Join-Path (Get-EchoHome) 'tools\EchoHTTP.psm1') -Force -DisableNameChecking
     Write-Host "✓ Loaded HTTP-based LLM functions" -ForegroundColor Green
   } catch {
     Write-Warning "Failed to load EchoHTTP module: $($_.Exception.Message)"
   }

3. Start llama-server first:
   
   .\tools\Start-LlamaServer.ps1 -ModelPath "D:\Echo\models\your-model.gguf" -Threads 4 -Ngl 999

4. Run Echo normally:
   
   .\Start-Echo.ps1

The HTTP functions will automatically replace the old file-based versions!

#>

Write-Host @"

════════════════════════════════════════════════════════════════
  Echo HTTP Module Loaded
════════════════════════════════════════════════════════════════
  
  Available functions:
  • Send-ResidentLLM     - HTTP-based prompt sending
  • Should-Interrupt     - HTTP-based routing
  • Invoke-LLM           - Generic completions
  • Test-LlamaServerHealth - Health check
  
  Server URL: $($env:ECHO_LLAMA_SERVER ?? "http://127.0.0.1:8080")
  
  Start llama-server first with:
    .\tools\Start-LlamaServer.ps1 -ModelPath "path\to\model.gguf" ``
      -Threads 4 -Ngl 999 -Batch 2048
      
════════════════════════════════════════════════════════════════

"@ -ForegroundColor Cyan
