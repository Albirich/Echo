#requires -Version 5.1
<#
.SYNOPSIS
  Simple HTTP wrapper for llama-server completions

.DESCRIPTION
  Simplified version that just wraps HTTP calls to llama-server.
  No process spawning, no complexity - just fast HTTP requests.

.PARAMETER Prompt
  The prompt text to send

.PARAMETER ServerUrl
  llama-server URL (default: from ECHO_LLAMA_SERVER env or http://127.0.0.1:8080)

.PARAMETER MaxTokens
  Maximum tokens to generate (default: 256)

.PARAMETER Temperature
  Sampling temperature (default: 0.7)

.PARAMETER Stop
  Stop sequences (default: <|im_end|>)

.PARAMETER JsonMode
  Force JSON output format

.PARAMETER TimeoutSec
  Request timeout in seconds (default: 120)

.EXAMPLE
  .\Send-LocalLLM.ps1 -Prompt "What is 2+2?" -MaxTokens 50
  
.EXAMPLE
  $result = .\Send-LocalLLM.ps1 -Prompt "List 3 colors" -JsonMode
#>

param(
  [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
  [string]$Prompt,
  
  [string]$ServerUrl = "",
  [int]$MaxTokens = 256,
  [double]$Temperature = 0.7,
  [string[]]$Stop = @("<|im_end|>", "<end_of_turn>"),
  [switch]$JsonMode,
  [int]$TimeoutSec = 120,
  [switch]$CachePrompt = $true
)

$ErrorActionPreference = 'Stop'

# Get server URL
if (-not $ServerUrl) {
  $ServerUrl = if ($env:ECHO_LLAMA_SERVER) { 
    $env:ECHO_LLAMA_SERVER 
  } else { 
    "http://127.0.0.1:8080" 
  }
}

# Build request body
$body = @{
  prompt = $Prompt
  n_predict = $MaxTokens
  temperature = $Temperature
  stop = $Stop
  cache_prompt = $CachePrompt.IsPresent
}

if ($JsonMode) {
  $body.grammar = 'json'
}

$bodyJson = ($body | ConvertTo-Json -Depth 5)

# Make HTTP request
try {
  $response = Invoke-RestMethod `
    -Uri "$ServerUrl/completion" `
    -Method Post `
    -Body $bodyJson `
    -ContentType "application/json; charset=utf-8" `
    -TimeoutSec $TimeoutSec `
    -ErrorAction Stop
  
  # Return cleaned response
  $result = $response.content
  if ($result) {
    # Clean up stop tokens
    foreach ($stopSeq in $Stop) {
      $result = $result -replace [regex]::Escape($stopSeq) + '.*$',''
    }
    Write-Output $result.Trim()
  } else {
    Write-Output ""
  }
  
} catch {
  Write-Error "llama-server request failed: $($_.Exception.Message)`n`nMake sure server is running at $ServerUrl"
  exit 1
}
