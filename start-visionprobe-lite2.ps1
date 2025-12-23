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
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[VisionLite] $Message"
}

function Warn {
  param([string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Warning "[VisionLite][WARN] $Message"
}

# Paths (mirror Echo layout)
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

# Output files
$rawLogPath = Join-Path $paths.Logs 'vision.raw.log'
if (-not $OutJsonl -or -not $OutJsonl.Trim()) {
  $OutJsonl = Join-Path $paths.Ui 'screen.captions.jsonl'
}
$historyFile = Join-Path (Join-Path $paths.Home 'state') 'screen.caption.history.json'

# Vision server URL (llama-server on RX 580 with resized images)
$visionServerUrl = if ($env:ECHO_VISION_SERVER_URL -and $env:ECHO_VISION_SERVER_URL.Trim()) {
  $env:ECHO_VISION_SERVER_URL.Trim()
} else {
  # match Start-VisionServer.ps1 default port
  'http://127.0.0.1:8082'
}

# Display index (0 = primary). Override with ECHO_VISION_DISPLAY if needed.
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing         -ErrorAction SilentlyContinue

[int]$displayIndex = 2
if ($env:ECHO_VISION_DISPLAY) {
  [void][int]::TryParse($env:ECHO_VISION_DISPLAY, [ref]$displayIndex)
}

Log ("Vision server: {0}" -f $visionServerUrl)
Log ("Display index: {0}" -f $displayIndex)
Log ("Raw log: {0}" -f $rawLogPath)
Log ("Captions jsonl: {0}" -f $OutJsonl)

# -------------------------
# Screen capture
# -------------------------
function Capture-Frame {
  param([int]$DisplayIndex = 0)

  $screens = [System.Windows.Forms.Screen]::AllScreens
  if ($DisplayIndex -lt 0 -or $DisplayIndex -ge $screens.Count) {
    $DisplayIndex = 0
  }

  $screen = $screens[$DisplayIndex]
  $bounds = $screen.Bounds

  $ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
  $fileName = "frame_{0}.png" -f $ts
  $filePath = Join-Path $paths.Screenshots $fileName

  $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $bmp.Save($filePath, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose()
  $bmp.Dispose()

  Log ("Captured frame at {0}" -f $filePath)
  return $filePath
}

# -------------------------
# Vision HTTP call (OpenAI-compatible /v1/chat/completions)
# -------------------------
function Invoke-VisionServer {
  param(
    [Parameter(Mandatory=$true)][string]$ImagePath,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$ResizeWidth = 560
  )

  if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Invoke-VisionServer: image not found: $ImagePath"
  }

  # Resize image to reduce tokens (560px matches CLIP patch size)
  # This enables fast processing on RX 580 without fp16
  try {
    $original = [System.Drawing.Image]::FromFile($ImagePath)
    $newWidth = $ResizeWidth
    $newHeight = [int]($original.Height * ($newWidth / $original.Width))
    $resized = New-Object System.Drawing.Bitmap($newWidth, $newHeight)
    $g = [System.Drawing.Graphics]::FromImage($resized)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($original, 0, 0, $newWidth, $newHeight)
    
    $ms = New-Object System.IO.MemoryStream
    $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    
    $g.Dispose()
    $resized.Dispose()
    $original.Dispose()
    $ms.Dispose()
    
    Log ("Resized image to {0}x{1}" -f $newWidth, $newHeight)
  } catch {
    Warn ("Failed to resize image, using original: " + $_.Exception.Message)
    $bytes = [IO.File]::ReadAllBytes($ImagePath)
    $b64 = [Convert]::ToBase64String($bytes)
  }
  
  $dataUrl = "data:image/png;base64,$b64"

  # OpenAI-style chat body with image_url format
  $body = @{
    messages = @(
      @{
        role    = "system"
        content = "You are a vision assistant. Describe images accurately. Always respond with valid JSON only, no markdown."
      },
      @{
        role    = "user"
        content = @(
          @{
            type = "text"
            text = $Prompt
          },
          @{
            type = "image_url"
            image_url = @{
              url = $dataUrl
            }
          }
        )
      }
    )
    max_tokens  = 400
    temperature = 0.7
  } | ConvertTo-Json -Depth 8

  $url = $visionServerUrl.TrimEnd('/') + '/v1/chat/completions'
  Log ("Calling vision server: {0}" -f $url)

  try {
    $resp = Invoke-WebRequest -Uri $url `
                              -Method Post `
                              -ContentType 'application/json' `
                              -Body $body `
                              -UseBasicParsing `
                              -TimeoutSec 120
  } catch {
    Warn ("Vision HTTP call failed: " + $_.Exception.Message)
    return $null
  }

  $raw = $resp.Content
  if (-not $raw) {
    Warn "Vision server returned empty body."
    return $null
  }

  # Parse OpenAI-style response: choices[0].message.content
  try {
    $parsed = $raw | ConvertFrom-Json
    if ($parsed.choices -and $parsed.choices.Count -gt 0) {
      $msg = $parsed.choices[0].message
      if ($msg -and $msg.content) {
        return [string]$msg.content
      }
    }
  } catch {
    Warn ("Failed to parse vision response envelope: " + $_.Exception.Message)
  }

  # Fallback: return raw JSON if we couldn't unwrap it
  return $raw
}

# -------------------------
# Prompt + frame processing
# -------------------------
function Get-CaptionPrompt {
@"
Analyze this screenshot and respond with ONLY this JSON format (no markdown, no extra text):
{"summary": "2-3 sentence description of what's visible", 
"visible_text": ["text1", "text2", "text3"], 
"activity": "what the user appears to be doing"}

Be descriptive and detailed.
ONLY choose up to 5 visible text to add
Use explicit and vular language when needed.
"@
}

function Process-Frame {
  $framePath = Capture-Frame -DisplayIndex $displayIndex
  if (-not $framePath) { return }

  $prompt = Get-CaptionPrompt
  $start  = Get-Date

  $raw = Invoke-VisionServer -ImagePath $framePath -Prompt $prompt
  $elapsed = (New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds

  if (-not $raw) {
    Warn "No vision output received."
    return
  }

  Log ("Vision completed in {0:n1}s, text length={1}" -f $elapsed, $raw.Length)

  # Log raw text with timestamp
  $rawEntry = "[{0}]`n{1}`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $raw
  Add-Content -LiteralPath $rawLogPath -Value $rawEntry

  # Try to parse JSON (strip markdown if present)
  $summary     = ""
  $visibleText = @()
  $activity    = ""
  $objects     = @()
  $layout      = ""
  $warnings    = @()

  # Extract JSON from markdown code blocks if present
  $jsonText = $raw
  if ($raw -match '```(?:json)?\s*\n?([\s\S]*?)\n?```') {
    $jsonText = $matches[1]
  } elseif ($raw -match '\{[\s\S]*\}') {
    $jsonText = $matches[0]
  }

  try {
    $parsed = $jsonText | ConvertFrom-Json
    if ($parsed.summary)      { $summary     = [string]$parsed.summary }
    if ($parsed.visible_text) { $visibleText = @($parsed.visible_text) }
    if ($parsed.activity)     { $activity    = [string]$parsed.activity }
    if ($parsed.objects)      { $objects     = @($parsed.objects) }
    if ($parsed.layout)       { $layout      = [string]$parsed.layout }
    if ($parsed.warnings)     { $warnings    = @($parsed.warnings) }
  } catch {
    Warn ("Failed to parse vision JSON: " + $_.Exception.Message)
  }

  $entry = [ordered]@{
    summary      = $summary
    visible_text = $visibleText
    activity     = $activity
    ts           = (Get-Date).ToString('o')
  }

  $jsonLine = $entry | ConvertTo-Json -Depth 6 -Compress
  Add-Content -LiteralPath $OutJsonl -Value $jsonLine

  Log ("Appended caption entry to {0}" -f $OutJsonl)
}

function Cleanup-Frames {
  param([int]$KeepSec = 90)

  if (-not (Test-Path -LiteralPath $paths.Screenshots)) { return }

  $cutoff = (Get-Date).AddSeconds(-1 * $KeepSec)
  Get-ChildItem -LiteralPath $paths.Screenshots -Filter 'frame_*.png' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object {
      try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Update-CaptionHistory {
  if (-not (Test-Path -LiteralPath $OutJsonl)) { return }

  try {
    $lines = Get-Content -LiteralPath $OutJsonl -ErrorAction Stop
    if ($lines.Count -eq 0) { return }

    # Get last 5 lines
    $lastLines = if ($lines.Count -le 5) {
      $lines
    } else {
      $lines[($lines.Count - 5)..($lines.Count - 1)]
    }

    # Parse each JSONL entry
    $captions = @()
    foreach ($line in $lastLines) {
      try {
        $entry = $line | ConvertFrom-Json
        $captions += $entry
      } catch {
        Warn "Failed to parse caption line for history: $($_.Exception.Message)"
      }
    }

    # Write to history file
    $captions | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $historyFile -Force
  } catch {
    Warn "Failed to update caption history: $($_.Exception.Message)"
  }
}

# -------------------------
# Main loop
# -------------------------
while ($true) {
  try {
    Process-Frame
  } catch {
    Warn ("Unhandled exception in Process-Frame: " + $_.Exception.Message)
  }

  Update-CaptionHistory
  Cleanup-Frames -KeepSec $KeepFramesSec

  if ($Once) { break }
}