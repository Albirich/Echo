[CmdletBinding()]
param(
  [switch]$Once,
  [int]$IntervalSec   = 0,
  [int]$KeepFramesSec = 90,
  [string]$OutJsonl
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# -------------------------
# Setup & helpers
# -------------------------
try {
  $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
} catch {
  $ScriptRoot = (Get-Location).Path
}

function Log {
  param([string]$Message)
  Write-Host "[VisionLite] $Message"
}

function Warn {
  param([string]$Message)
  Write-Warning "[VisionLite][WARN] $Message"
}

$paths = [ordered]@{
  Home   = $ScriptRoot
  Logs   = Join-Path $ScriptRoot 'logs'
  Ui     = Join-Path $ScriptRoot 'ui'
  Sense  = Join-Path $ScriptRoot 'sense'
}
$paths.Screenshots = Join-Path $paths.Sense 'screenshots'

$paths.Values | ForEach-Object {
  if (-not (Test-Path -LiteralPath $_)) {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
  }
}

$env:ECHO_HOME = $paths.Home
$rawLogPath = Join-Path $paths.Logs 'vision.raw.log'
if (-not $OutJsonl -or -not $OutJsonl.Trim()) {
  $OutJsonl = Join-Path $paths.Ui 'screen.captions.jsonl'
}
$historyFile = Join-Path (Join-Path $paths.Home 'state') 'screen.caption.history.json'

$visionServerUrl = if ($env:ECHO_VISION_SERVER_URL -and $env:ECHO_VISION_SERVER_URL.Trim()) {
  $env:ECHO_VISION_SERVER_URL.Trim()
} else {
  'http://127.0.0.1:8082'
}

# Locked to Monitor 0
[int]$displayIndex = 0

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing       -ErrorAction SilentlyContinue

Log ("Vision server: {0}" -f $visionServerUrl)
Log ("Locked to Monitor index: {0}" -f $displayIndex)

# -------------------------
# In-Memory Screen capture
# -------------------------
function Get-ScreenAsBase64 {
  param([int]$Index = 0, [int]$ResizeWidth = 400)

  try {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    if ($Index -ge $screens.Count) { $Index = 0 }
    
    $screen = $screens[$Index]
    $bounds = $screen.Bounds

    # Capture
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)

    # Resize
    $newHeight = [int]($bounds.Height * ($ResizeWidth / $bounds.Width))
    $resized = New-Object System.Drawing.Bitmap($ResizeWidth, $newHeight)
    $gr = [System.Drawing.Graphics]::FromImage($resized)
    $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gr.DrawImage($bmp, 0, 0, $ResizeWidth, $newHeight)

    # To Base64
    $ms = New-Object System.IO.MemoryStream
    $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $b64 = [Convert]::ToBase64String($ms.ToArray())

    # Cleanup
    $ms.Dispose(); $gr.Dispose(); $resized.Dispose(); $g.Dispose(); $bmp.Dispose()
    
    return "data:image/png;base64,$b64"
  } catch {
    Warn "Failed in-memory capture: $($_.Exception.Message)"
    return $null
  }
}

# -------------------------
# Vision HTTP call
# -------------------------
function Invoke-VisionServer {
  param([string]$Base64Image, [string]$Prompt)

  $body = @{
    messages = @(
      @{ role = "system"; content = "You are a vision assistant. Describe images accurately. Always respond with valid JSON only, no markdown." },
      @{ role = "user"; content = @(
          @{ type = "text"; text = $Prompt },
          @{ type = "image_url"; image_url = @{ url = $Base64Image } }
        )
      }
    )
    max_tokens  = 400
    temperature = 0.7
  } | ConvertTo-Json -Depth 8

  $url = $visionServerUrl.TrimEnd('/') + '/v1/chat/completions'
  try {
    $resp = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 120
    $parsed = $resp.Content | ConvertFrom-Json
    return $parsed.choices[0].message.content
  } catch {
    Warn ("Vision call failed: " + $_.Exception.Message)
    return $null
  }
}

function Get-CaptionPrompt {
@"
TASK: Analyze this screenshot.
REQUIREMENT: Respond ONLY with a JSON object. No preamble, no markdown blocks, no conversational filler.

{
  "summary": "Detailed 2-3 sentence description.", 
  "visible_text": ["list", "up to", "5 items"]
}

Note: Use explicit/vulgar language if appropriate to the content.
"@
}

function Process-Frame {
  $b64 = Get-ScreenAsBase64 -Index $displayIndex -ResizeWidth 400 # Optimized width
  if (-not $b64) { return }

  $start = Get-Date
  $raw = Invoke-VisionServer -Base64Image $b64 -Prompt (Get-CaptionPrompt)
  $elapsed = (New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds

  if (-not $raw) { return }

  Log ("Vision completed in {0:n1}s" -f $elapsed)
  Add-Content -LiteralPath $rawLogPath -Value "[$(Get-Date)]`n$raw`n"

  # IMPROVED JSON EXTRACTION: Find anything between the first { and last }
  $jsonMatch = $raw -match '(?s)(\{.*\})'
  if ($jsonMatch) {
    $jsonText = $matches[1]
    try {
      $parsed = $jsonText | ConvertFrom-Json
      $entry = [ordered]@{
        summary      = $parsed.summary
        visible_text = $parsed.visible_text
        ts           = (Get-Date).ToString('o')
      }
      $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $OutJsonl
    } catch {
      Warn "JSON Parse failed. AI returned: $($raw.Substring(0, [math]::Min(50, $raw.Length)))..."
    }
  } else {
    Warn "No JSON structure found in AI response."
  }
}function Update-CaptionHistory {
  if (-not (Test-Path $OutJsonl)) { return }
  try {
    $lines = Get-Content $OutJsonl -Tail 5
    $captions = foreach($l in $lines) { $l | ConvertFrom-Json }
    $captions | ConvertTo-Json -Depth 10 | Set-Content $historyFile -Force
  } catch {}
}

# -------------------------
# Main loop
# -------------------------
while ($true) {
  Process-Frame
  Update-CaptionHistory
  if ($Once) { break }
  if ($IntervalSec -gt 0) { Start-Sleep -Seconds $IntervalSec }
}