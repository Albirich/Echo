param(
  [string]$BaseUrl = $env:ECHO_LLAMA_SERVER,
  [string]$Model   = $env:ECHO_LLAMA_MODEL,
  [Parameter(Mandatory)][string]$UserText,
  [int]$MaxTokens = 512,
  [double]$Temperature = 0.7
)

function Invoke-PostJson($url, $obj, $timeout=60) {
  $json = $obj | ConvertTo-Json -Depth 8
  try {
    Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $json -TimeoutSec $timeout
  } catch {
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { throw $_.ErrorDetails.Message }
    else { throw $_.Exception.Message }
  }
}

if (-not $BaseUrl) { throw "ECHO_LLAMA_SERVER not set" }
if (-not $Model)   { throw "ECHO_LLAMA_MODEL not set"  }

# 1) Try OpenAI chat
$chatBody = @{
  model = $Model
  messages = @(@{ role = "user"; content = $UserText })
  max_tokens = $MaxTokens
  temperature = $Temperature
  stream = $false
}

try {
  $resp = Invoke-PostJson ($BaseUrl.TrimEnd('/') + '/chat/completions') $chatBody 60
  $content = $resp.choices[0].message.content
  if ($content) { return $content.Trim() }
} catch {
  # 2) Fallback to /completion (works great with Gemma/instruct)
  $legacyBody = @{ prompt = $UserText; n_predict = [Math]::Min($MaxTokens, 256) }
  $legacy = Invoke-PostJson (($BaseUrl -replace '/v1$','').TrimEnd('/') + '/completion') $legacyBody 60
  if ($legacy -and $legacy.content) { return ($legacy.content | Out-String).Trim() }
  throw $_
}
