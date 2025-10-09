<# 
  Start-VisionProbe-Burst.ps1
  - Captures bursts of screenshots at ~3fps for 2-3 seconds
  - Sends frames to LLaVA for consolidated caption
  - Keeps last 60 seconds of frames in sense/screenshots
  - Writes screen.caption.json for IM consumption
#>

param(
  [switch]$Once,
  [int]$BurstIntervalSec = 5,   # How often to do a burst capture
  [int]$BurstDurationSec = 2,   # How long each burst lasts
  [int]$BurstFPS = 3,            # Frames per second during burst
  [int]$KeepFramesSec = 60,     # Keep this many seconds of frames
  [int]$StartDelaySec = 3,      # Delay before starting capture
  [switch]$Force
)

# ------------------ Config / Defaults ------------------
$HomeDir      = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { 'D:\Echo' }
$StateDir     = if ($env:STATE_DIR -and $env:STATE_DIR.Trim()) { $env:STATE_DIR } else { Join-Path $HomeDir 'state' }
$ScreenshotDir = Join-Path $HomeDir 'sense\screenshots'
$OllamaHost   = if ($env:OLLAMA_HOST -and $env:OLLAMA_HOST.Trim()) { $env:OLLAMA_HOST } else { 'http://127.0.0.1:11434' }
$VisionModel  = if ($env:VISION_MODEL -and $env:VISION_MODEL.Trim()) { $env:VISION_MODEL } else { 'llava:7b' }

$CaptionPath  = Join-Path $StateDir 'screen.caption.json'
$PidFile      = Join-Path $StateDir 'visionprobe.pid'
$StopFile     = Join-Path $StateDir 'visionprobe.stop'

$HostFlagPath = $env:ECHO_HOST_FLAG
$StopFlagEnv  = $env:ECHO_STOP_FLAG
$env:OLLAMA_HOST = 'http://127.0.0.1:11434'

# ------------------ Helpers ------------------
function IsoNow { (Get-Date).ToString('o') }
function UnixTime { [int][double]::Parse((Get-Date -UFormat %s)) }

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function AtomicWrite-Text([string]$Path,[string]$Content,[System.Text.Encoding]$Encoding) {
  $tmp = $Path + '.tmp'
  [System.IO.File]::WriteAllText($tmp, $Content, $Encoding)
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Enter-Singleton {
  if (Test-Path -LiteralPath $PidFile) {
    try {
      $old = Get-Content -LiteralPath $PidFile -ErrorAction Stop
      if ($old -match '^\d+$') {
        $opid = [int]$old
        if (Get-Process -Id $opid -ErrorAction SilentlyContinue) {
          Write-Host "[VisionProbe] Already running (PID=$opid). Exiting."
          exit 0
        }
      }
    } catch {}
  }
  $PID | Out-File -LiteralPath $PidFile -Encoding ascii -Force
  Register-EngineEvent PowerShell.Exiting -Action {
    try { Remove-Item -LiteralPath $using:PidFile -Force -ErrorAction SilentlyContinue } catch {}
  } | Out-Null
}

# P/Invoke for window tracking
try {
  Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace Native {
  public static class WinApi {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    public const int MONITOR_DEFAULTTONEAREST = 2;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
    public struct MONITORINFO {
      public int cbSize;
      public RECT rcMonitor;
      public RECT rcWork;
      public uint dwFlags;
    }
  }
}
"@
} catch {}

try { Add-Type -AssemblyName System.Drawing | Out-Null } catch {}

function Get-ActiveWindowInfo {
  $h = [Native.WinApi]::GetForegroundWindow()
  if ($h -eq [IntPtr]::Zero) {
    return @{ hwnd=0; title=$null; process=$null; exe=$null; bounds=$null; mon=$null }
  }

  $sb = New-Object System.Text.StringBuilder 512
  [void][Native.WinApi]::GetWindowText($h, $sb, $sb.Capacity)
  $title = $sb.ToString()

  $rc = New-Object Native.WinApi+RECT
  [void][Native.WinApi]::GetWindowRect($h, [ref]$rc)
  $bounds = @{ left=$rc.Left; top=$rc.Top; right=$rc.Right; bottom=$rc.Bottom }

  $mi = New-Object Native.WinApi+MONITORINFO
  $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][Native.WinApi+MONITORINFO])
  $monH = [Native.WinApi]::MonitorFromWindow($h, [Native.WinApi]::MONITOR_DEFAULTTONEAREST)
  $mon = $null
  if ($monH -ne [IntPtr]::Zero -and [Native.WinApi]::GetMonitorInfo($monH, [ref]$mi)) {
    $mon = @{
      left   = $mi.rcMonitor.Left
      top    = $mi.rcMonitor.Top
      right  = $mi.rcMonitor.Right
      bottom = $mi.rcMonitor.Bottom
    }
  }

  $procId = 0
  [void][Native.WinApi]::GetWindowThreadProcessId($h, [ref]$procId)
  $p = $null
  try { $p = Get-Process -Id $procId -ErrorAction Stop } catch {}

  return @{
    hwnd    = $h.ToInt64()
    title   = $title
    process = if ($p) { $p.ProcessName } else { $null }
    exe     = if ($p) { $p.Path } else { $null }
    bounds  = $bounds
    mon     = $mon
  }
}

function Capture-MonitorFrame([hashtable]$WindowInfo, [string]$Path) {
  if (-not $WindowInfo -or -not $WindowInfo.mon) { return $false }
  $m = $WindowInfo.mon
  $mx = [int]$m.left
  $my = [int]$m.top
  $mw = [int]($m.right  - $m.left)
  $mh = [int]($m.bottom - $m.top)
  if ($mw -le 0 -or $mh -le 0) { return $false }

  $bmp = New-Object System.Drawing.Bitmap($mw, $mh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen([System.Drawing.Point]::new($mx,$my),
                      [System.Drawing.Point]::new(0,0),
                      [System.Drawing.Size]::new($mw,$mh))
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $true
  } finally { $g.Dispose(); $bmp.Dispose() }
}

function Capture-Burst {
  param([int]$Duration, [int]$FPS)
  
  Ensure-Dir $ScreenshotDir
  
  $frames = @()
  $totalFrames = $Duration * $FPS
  $delayMs = [int](1000.0 / $FPS)
  
  Write-Host "[VisionProbe] Starting burst: $totalFrames frames at ${FPS}fps"
  
  $win = Get-ActiveWindowInfo
  
  for ($i = 0; $i -lt $totalFrames; $i++) {
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $framePath = Join-Path $ScreenshotDir "frame_$timestamp.png"
    
    $captureOk = Capture-MonitorFrame -WindowInfo $win -Path $framePath
    
    if ($captureOk) {
      $frames += $framePath
    }
    
    if ($i -lt ($totalFrames - 1)) {
      Start-Sleep -Milliseconds $delayMs
    }
  }
  
  Write-Host "[VisionProbe] Captured $($frames.Count) frames"
  
  return @{
    frames = $frames
    window = $win
  }
}

function Cleanup-OldFrames {
  param([int]$KeepSeconds)
  
  if (-not (Test-Path -LiteralPath $ScreenshotDir)) { return }
  
  $cutoff = (Get-Date).AddSeconds(-$KeepSeconds)
  $files = Get-ChildItem -LiteralPath $ScreenshotDir -Filter "frame_*.png" -File
  
  foreach ($f in $files) {
    if ($f.LastWriteTime -lt $cutoff) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-LLaVABurst {
  param(
    [string]$OllamaHostUri,
    [string]$Model,
    [string]$Prompt,
    [string[]]$ImagePaths,
    [int]$TimeoutSec = 120
  )

  if (-not $Model -or $ImagePaths.Count -eq 0) { return $null }

  try {
    # Encode all frames to base64
    $images = @()
    foreach ($path in $ImagePaths) {
      if (Test-Path -LiteralPath $path) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $b64 = [System.Convert]::ToBase64String($bytes)
        $images += $b64
      }
    }
    
    if ($images.Count -eq 0) { return $null }

    # Build prompt with frame context
    $fullPrompt = @"
$Prompt

You are analyzing $($images.Count) sequential frames captured over ~2 seconds.
Describe what happened during this sequence - actions, changes, events, context.
Focus on the experience and narrative, not technical details.
"@

    # Try /api/chat with multiple images
    $body = @{
      model    = $Model
      stream   = $false
      messages = @(@{
        role    = 'user'
        content = $fullPrompt
        images  = $images
      })
      options = @{
        temperature = 0.3
        num_predict = 400
	gpu_layers=999 
      }
    } | ConvertTo-Json -Depth 20

    $uri = ($OllamaHostUri.TrimEnd('/')) + '/api/chat'
    $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop
    
    if ($resp -and $resp.message -and $resp.message.content) {
      return [string]$resp.message.content
    }

    return $null
  } catch {
    Write-Warning "[VisionProbe] LLaVA error: $($_.Exception.Message)"
    return $null
  }
}

function Run-VisionBurst {
  Ensure-Dir $StateDir
  Ensure-Dir $ScreenshotDir

  # Check host flag
  $hostOk = $Force -or ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath))
  if (-not $hostOk) {
    Write-Host "[VisionProbe] Host flag missing; skipping burst."
    return
  }

  # Capture burst
  $burst = Capture-Burst -Duration $BurstDurationSec -FPS $BurstFPS
  
  if ($burst.frames.Count -eq 0) {
    Write-Warning "[VisionProbe] No frames captured"
    return
  }

  # Get consolidated caption from LLaVA
  $prompt = @"
You are viewing a sequence of $($burst.frames.Count) screenshots taken over 2 seconds.

Your task: Describe what the USER is DOING, not what you see frame-by-frame.

Examples:
- "User is coding in Visual Studio, actively typing and scrolling through a Python file"
- "User playing Minecraft, mining underground while low on health"
- "User browsing Reddit, scrolling through posts on the homepage"
- "User in Discord voice chat while playing a game"

Focus on:
- The primary activity/task
- Any significant changes or events during the sequence
- Context that matters (low health, error messages, incoming notifications)

Keep it to 2-3 sentences maximum. Be concrete and specific.
"@

  $caption = Invoke-LLaVABurst -OllamaHostUri $OllamaHost -Model $VisionModel -Prompt $prompt -ImagePaths $burst.frames -TimeoutSec 120

  # Build caption document
  $doc = @{
    ts = IsoNow
    active_window = @{
      title = $burst.window.title
      process = $burst.window.process
      exe = $burst.window.exe
    }
    burst = @{
      frame_count = $burst.frames.Count
      duration_sec = $BurstDurationSec
      fps = $BurstFPS
      first_frame = (Split-Path -Leaf $burst.frames[0])
      last_frame = (Split-Path -Leaf $burst.frames[-1])
    }
    summary = if ($caption) { $caption } else { "Unable to generate caption" }
    salient = @()
  }

  # Simple salient extraction from caption
  if ($caption) {
    $sentences = $caption -split '[.!?]' | Where-Object { $_.Trim().Length -gt 10 }
    $doc.salient = @($sentences | Select-Object -First 3 | ForEach-Object { $_.Trim() })
  }

  # Write caption
  $json = $doc | ConvertTo-Json -Depth 10
  AtomicWrite-Text -Path $CaptionPath -Content $json -Encoding ([System.Text.Encoding]::UTF8)

  Write-Host "[VisionProbe] Caption written: $($caption.Length) chars"

  # Cleanup old frames
  Cleanup-OldFrames -KeepSeconds $KeepFramesSec
}

# ------------------ Main ------------------
Ensure-Dir $StateDir
Ensure-Dir $ScreenshotDir
Enter-Singleton

Write-Host "[VisionProbe] Starting burst mode: ${BurstFPS}fps for ${BurstDurationSec}s every ${BurstIntervalSec}s"
Write-Host "[VisionProbe] Keeping last ${KeepFramesSec}s of frames"
Write-Host "[VisionProbe] Model: $VisionModel"

if ($Once) {
  Run-VisionBurst
  return
}

while ($true) {
  try {
    # Check stop flags
    if (Test-Path -LiteralPath $StopFile) {
      Write-Host "[VisionProbe] Stop flag found, exiting."
      break
    }
    if ($StopFlagEnv -and (Test-Path -LiteralPath $StopFlagEnv)) {
      Write-Host "[VisionProbe] Global stop flag found, exiting."
      break
    }

    # Check host flag
    if (-not $Force -and -not ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath))) {
      Write-Host "[VisionProbe] Host flag missing, exiting."
      break
    }

    Run-VisionBurst
  } catch {
    Write-Warning "[VisionProbe] Error: $($_.Exception.Message)"
  }

  Start-Sleep -Seconds ([Math]::Max(1, $BurstIntervalSec))
}
