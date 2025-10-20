<# 
  Start-VisionProbe-Burst.ps1
  - Captures a single screenshot on a fixed interval (no burst)
  - Sends the screenshot to LLaVA for caption
  - Keeps recent frames in sense/screenshots
  - Writes screen.caption.json for IM consumption
#>

param(
  [switch]$Once,
  [int]$BurstIntervalSec = 5,   # How often to capture (kept name for compatibility)
  [int]$BurstDurationSec = 2,   # Unused in single-shot mode
  [int]$BurstFPS = 3,           # Unused in single-shot mode
  [int]$KeepFramesSec = 60,     # Keep this many seconds of frames
  [int]$StartDelaySec = 3,      # Delay before starting capture
  [switch]$Force
)

# ------------------ Config / Defaults ------------------
$HomeDir      = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { 'D:\Echo' }
$StateDir     = if ($env:STATE_DIR -and $env:STATE_DIR.Trim()) { $env:STATE_DIR } else { Join-Path $HomeDir 'state' }
$ScreenshotDir = Join-Path $HomeDir 'sense\screenshots'
$LlamaExe     = if ($env:LLAMA_VISION_EXE -and (Test-Path $env:LLAMA_VISION_EXE)) { $env:LLAMA_VISION_EXE }
               elseif (Test-Path 'D:\\llama-cpp\\llama-mtmd-cli.exe') { 'D:\\llama-cpp\\llama-mtmd-cli.exe' }
               elseif ($env:LLAMA_EXE -and (Test-Path $env:LLAMA_EXE)) { $env:LLAMA_EXE }
               else { 'D:\\llama-cpp\\llama-cli.exe' }
# Resolve local llama.cpp vision model path (prefer env; then Qwen2.5-VL caption models; else LLaVA fallback)
$VisionModelPath = $null
if ($env:ECHO_VISION_LLAMACPP_MODEL -and (Test-Path $env:ECHO_VISION_LLAMACPP_MODEL)) { $VisionModelPath = $env:ECHO_VISION_LLAMACPP_MODEL }
elseif ($env:ECHO_LLAMACPP_VISION_MODEL -and (Test-Path $env:ECHO_LLAMACPP_VISION_MODEL)) { $VisionModelPath = $env:ECHO_LLAMACPP_VISION_MODEL }
elseif ($env:VISION_MODEL -and (Test-Path $env:VISION_MODEL)) { $VisionModelPath = $env:VISION_MODEL }
else {
  $searchDirs = @((Join-Path $HomeDir 'models'), (Join-Path $HomeDir 'model'))
  $qwen = $null
  foreach ($d in $searchDirs) {
    try {
      if (Test-Path $d) {
        $qwen = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'Qwen(2\.5|2p5)?-VL.*Caption.*\.gguf$' -or $_.Name -match 'Qwen2\.5-VL-3B-Abliterated-Caption-it.*\.gguf$' } |
                Sort-Object Length -Descending |
                Select-Object -First 1
        if ($qwen) { break }
      }
    } catch {}
  }
  if ($qwen) { $VisionModelPath = $qwen.FullName }
}
if (-not $VisionModelPath) {
  if (Test-Path (Join-Path $HomeDir 'model\\llava-phi-3-mini-f16.gguf')) { $VisionModelPath = (Join-Path $HomeDir 'model\\llava-phi-3-mini-f16.gguf') }
  elseif (Test-Path (Join-Path $HomeDir 'models\\llava-phi-3-mini-f16.gguf')) { $VisionModelPath = (Join-Path $HomeDir 'models\\llava-phi-3-mini-f16.gguf') }
  else { $VisionModelPath = 'D:\\Echo\\models\\llava-phi-3-mini-f16.gguf' }
}

# Optional mmproj (only needed for LLaVA models)
$VisionMmproj = $null
if ($VisionModelPath -match 'llava') {
  if ($env:ECHO_VISION_MMPROJ -and (Test-Path $env:ECHO_VISION_MMPROJ)) {
    $VisionMmproj = $env:ECHO_VISION_MMPROJ
  } else {
    # Try common names in the model directory and models folder
    $tryDirs = @()
    if ($VisionModelPath -and (Test-Path $VisionModelPath)) { $tryDirs += (Split-Path -Parent $VisionModelPath) }
    $tryDirs += (Join-Path $HomeDir 'models')
    foreach ($d in $tryDirs) {
      try {
        if (Test-Path $d) {
          $mm = Get-ChildItem -LiteralPath $d -Filter '*mmproj*.gguf' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'llava' } |
               Select-Object -First 1
          if ($mm) { $VisionMmproj = $mm.FullName; break }
        }
      } catch {}
    }
  }
}

# GPU layers for vision
$VisionGpuLayers = 999
try { if ($env:ECHO_VISION_GPU_LAYERS -and $env:ECHO_VISION_GPU_LAYERS.Trim()) { $VisionGpuLayers = [int]$env:ECHO_VISION_GPU_LAYERS } } catch {}
try { if ($VisionGpuLayers -eq 999 -and $env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { $VisionGpuLayers = [int]$env:ECHO_LLAMA_GPU_LAYERS } } catch {}

# Optional perf tuning
$VisionThreads   = 0
try { if ($env:ECHO_VISION_THREADS -and $env:ECHO_VISION_THREADS.Trim()) { $VisionThreads = [int]$env:ECHO_VISION_THREADS } } catch {}
$VisionNPredict  = 200
try { if ($env:ECHO_VISION_NPREDICT -and $env:ECHO_VISION_NPREDICT.Trim()) { $VisionNPredict = [int]$env:ECHO_VISION_NPREDICT } } catch {}

# Context size (lower = faster load + less RAM)
$VisionCtxSize = 2048
try { if ($env:ECHO_VISION_CTX -and $env:ECHO_VISION_CTX.Trim()) { $VisionCtxSize = [int]$env:ECHO_VISION_CTX } } catch {}

# Optional interval override via env
try { if ($env:ECHO_VISION_INTERVAL_SEC -and $env:ECHO_VISION_INTERVAL_SEC.Trim()) { $BurstIntervalSec = [int]$env:ECHO_VISION_INTERVAL_SEC } } catch {}

# Capture mode: window-only for speed unless disabled
$CaptureWindowOnly = $true
try { if ($env:ECHO_VISION_WINDOW_ONLY -and ($env:ECHO_VISION_WINDOW_ONLY -match '^(0|false|no)$')) { $CaptureWindowOnly = $false } } catch {}

# Optional HuggingFace repo fallback (auto-downloads model + projector when provided)
$VisionHf = $null
try { if ($env:ECHO_VISION_HF -and $env:ECHO_VISION_HF.Trim()) { $VisionHf = $env:ECHO_VISION_HF.Trim() } } catch {}
# Auto-default HF repo for known model names if not explicitly provided
if (-not $VisionHf) {
  try {
    $leaf = if ($VisionModelPath) { (Split-Path -Leaf $VisionModelPath) } else { '' }
    if ($leaf -match 'llava-phi-3-mini') { $VisionHf = 'xtuner/llava-phi-3-mini-gguf' }
  } catch {}
}

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

# Save JPEG with quality (smaller than PNG; faster IO)
function Save-Jpeg([System.Drawing.Bitmap]$Bitmap, [string]$Path, [int]$Quality=85) {
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  if (-not $codec) { $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg); return }
  $encParms = New-Object System.Drawing.Imaging.EncoderParameters 1
  $encParms.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
  $Bitmap.Save($Path, $codec, $encParms)
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

function Capture-Frame([hashtable]$WindowInfo, [string]$PathJpg, [switch]$WindowOnly) {
  if (-not $WindowInfo) { return $false }
  $srcX = 0; $srcY = 0; $w = 0; $h = 0
  if ($WindowOnly -and $WindowInfo.bounds) {
    $b = $WindowInfo.bounds
    $srcX = [int]$b.left; $srcY = [int]$b.top
    $w = [int]([math]::Max(1, $b.right - $b.left))
    $h = [int]([math]::Max(1, $b.bottom - $b.top))
  } elseif ($WindowInfo.mon) {
    $m = $WindowInfo.mon
    $srcX = [int]$m.left; $srcY = [int]$m.top
    $w = [int]([math]::Max(1, $m.right - $m.left))
    $h = [int]([math]::Max(1, $m.bottom - $m.top))
  } else { return $false }

  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen([System.Drawing.Point]::new($srcX,$srcY), [System.Drawing.Point]::new(0,0), [System.Drawing.Size]::new($w,$h))
    Save-Jpeg -Bitmap $bmp -Path $PathJpg -Quality 85
    return $true
  } finally { $g.Dispose(); $bmp.Dispose() }
}

function Capture-One {
  Ensure-Dir $ScreenshotDir
  $win = Get-ActiveWindowInfo
  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $framePath = Join-Path $ScreenshotDir "frame_$timestamp.jpg"
  $frames = @()
  if (Capture-Frame -WindowInfo $win -PathJpg $framePath -WindowOnly:([bool]$CaptureWindowOnly)) {
    $frames += $framePath
    Write-Host "[VisionProbe] Captured 1 frame"
  } else {
    Write-Warning "[VisionProbe] Failed to capture screenshot"
  }
  return @{
    frames = $frames
    window = $win
  }
}

function Compose-FallbackCaption {
  param([hashtable]$Win)
  $title = if ($Win.title) { $Win.title.Trim() } else { '' }
  $proc  = if ($Win.process) { $Win.process.Trim() } else { '' }
  $titleClean = $title
  if ($titleClean) {
    $titleClean = $titleClean -replace ' - (Google Chrome|Microsoft Edge|Mozilla Firefox)$',''
    $titleClean = $titleClean -replace ' - Visual Studio Code$',''
    $titleClean = $titleClean -replace ' - Discord$',''
  }
  if ($proc -match 'chrome|msedge|firefox') {
    if ($titleClean) { return "Browsing — $titleClean" } else { return "Browsing the web" }
  }
  if ($proc -match 'Code|devenv|idea64|pycharm|clion|sublime|atom') {
    if ($titleClean) { return "Coding in $proc — $titleClean" } else { return "Coding in $proc" }
  }
  if ($proc -match 'Discord') {
    if ($titleClean) { return "Using Discord — $titleClean" } else { return "Using Discord" }
  }
  if ($proc -match 'steam|Spotify|notion|obs64|word|excel|powerpnt') {
    if ($titleClean) { return "$proc — $titleClean" } else { return "Using $proc" }
  }
  if ($proc -and $titleClean) { return "Using $proc — $titleClean" }
  elseif ($titleClean)        { return "Viewing: $titleClean" }
  elseif ($proc)              { return "Using $proc" }
  else                        { return "Viewing the desktop" }
}

function Cleanup-OldFrames {
  param([int]$KeepSeconds)
  
  if (-not (Test-Path -LiteralPath $ScreenshotDir)) { return }
  
  $cutoff = (Get-Date).AddSeconds(-$KeepSeconds)
  $files = @(Get-ChildItem -LiteralPath $ScreenshotDir -Filter "frame_*.jpg" -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $ScreenshotDir -Filter "frame_*.png" -File -ErrorAction SilentlyContinue)
  
  foreach ($f in $files) {
    if ($f.LastWriteTime -lt $cutoff) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-LLaVABurst {
  param(
    [string]$Prompt,
    [string[]]$ImagePaths,
    [int]$TimeoutSec = 120
  )
  if (-not $VisionModelPath -or -not (Test-Path $VisionModelPath)) { return $null }
  $validImages = @(); foreach ($img in $ImagePaths) { if (Test-Path $img) { $validImages += $img } }
  if ($validImages.Count -eq 0) { return $null }

  # Decide best llama binary: avoid mtmd CLI for Qwen/vision models without projector
  $exeToUse = $LlamaExe
  $leaf = try { if ($VisionModelPath) { (Split-Path -Leaf $VisionModelPath) } else { '' } } catch { '' }
  $isLlava  = ($leaf -match 'llava')
  $isQwen   = ($leaf -match 'qwen')
  $mtmdPath = 'D:\\llama-cpp\\llama-mtmd-cli.exe'
  $stdPath  = 'D:\\llama-cpp\\llama-cli.exe'
  if ($exeToUse -and (Split-Path -Leaf $exeToUse) -ieq 'llama-mtmd-cli.exe') {
    if (-not $isLlava -or -not ($VisionMmproj -and (Test-Path $VisionMmproj))) {
      if (Test-Path $stdPath) { $exeToUse = $stdPath }
    }
  } elseif (-not (Test-Path $exeToUse)) {
    if (Test-Path $stdPath) { $exeToUse = $stdPath }
    elseif (Test-Path $mtmdPath -and $isLlava -and $VisionMmproj -and (Test-Path $VisionMmproj)) { $exeToUse = $mtmdPath }
  }
  if (-not (Test-Path $exeToUse)) { Write-Warning "[VisionProbe] Llama exe not found: $exeToUse"; return $null }

  # Use the robust wrapper that already handles arg compatibility and output cleaning
  $runner = Join-Path $HomeDir 'tools\Start-LocalLLM.ps1'
  if (-not (Test-Path $runner)) { Write-Warning "[VisionProbe] Runner not found: $runner"; return $null }

  $logsDir = Join-Path $HomeDir 'logs'; Ensure-Dir $logsDir
  $ts = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
  $pf = Join-Path $logsDir ("vision-prompt-$ts.txt")
  try { [IO.File]::WriteAllText($pf, $Prompt, [Text.UTF8Encoding]::new($false)) } catch { return $null }

  $args = @(
    '-PromptFile', $pf,
    '-ModelPath',  $VisionModelPath,
    '-LlamaExe',   $exeToUse,
    '-CtxSize',    $VisionCtxSize,
    '-GpuLayers',  $VisionGpuLayers,
    '-MaxTokens',  $VisionNPredict,
    '-Temp',       0.3
  )
  if ($VisionMmproj -and (Test-Path $VisionMmproj)) { $args += @('-Mmproj', $VisionMmproj) }
  foreach ($img in $validImages) { $args += @('-Images', $img) }

  try {
    $out = & $runner @args 2>$null
    $text = ($out | Out-String).Trim()
    if (-not $text) { return $null }
    if ($text -match '^Experimental CLI for multimodal' -or $text -match '^Usage: .*llama-mtmd-cli') { return $null }
    return $text
  } catch {
    Write-Warning "[VisionProbe] llama.cpp vision error: $($_.Exception.Message)"
    return $null
  } finally {
    try { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Run-VisionBurst {
  Ensure-Dir $StateDir
  Ensure-Dir $ScreenshotDir

  # Check host flag
  $hostOk = $Force -or ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath))
  if (-not $hostOk) {
    Write-Host "[VisionProbe] Host flag missing; skipping capture."
    return
  }

  # Capture single screenshot
  $burst = Capture-One
  
  if ($burst.frames.Count -eq 0) {
    Write-Warning "[VisionProbe] No screenshot captured"
    return
  }

  # Get caption from llama.cpp (single screenshot)
  $prompt = @"
You are a vision captioner. Describe the visible content of this screenshot.

Instructions:
- Name the application/site and the specific view or panel on screen.
- Quote 2–4 key on-screen texts exactly (e.g., headings, file names, video titles).
- Mention notable UI elements (tabs, sidebars, code blocks, media player controls, dialogs, notifications).
- If code or data is visible, state the language/type and the specific file or resource.
- If a browser page, state the site and what the page is (watching a video, reading an article, search results, etc.).
- Avoid speculation; only describe what is visible. Do not use generic phrases like "coding" or "browsing" unless supported by visible elements.
- Do not rely on hints unless that text actually appears on screen.
- Describe the visuals on the screen, as if you were telling someone what you see.

Grounding hints (use only if they match visible text):
- Active window title: ""$($burst.window.title)""
- Process: ""$($burst.window.process)""

Format: 2–3 concise sentences packed with specifics.
"@

  $caption = Invoke-LLaVABurst -Prompt $prompt -ImagePaths $burst.frames -TimeoutSec 120
  if (-not $caption -or -not $caption.Trim()) {
    Write-Host "[VisionProbe] Empty caption; retrying with minimal prompt..."
    $retryPrompt = "Describe exactly what is visible on screen in 2 concise sentences, quoting at least one visible text string."
    $caption = Invoke-LLaVABurst -Prompt $retryPrompt -ImagePaths $burst.frames -TimeoutSec 160
  }
  if (-not $caption -or -not $caption.Trim()) {
    Write-Warning "[VisionProbe] Vision caption unavailable; using fallback from active window."
    $caption = Compose-FallbackCaption $burst.window
  }

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
      duration_sec = 0
      fps = 0
      first_frame = (Split-Path -Leaf $burst.frames[0])
      last_frame = (Split-Path -Leaf $burst.frames[-1])
    }
    summary = $caption
    salient = @()
  }

  # Salient extraction: prefer quoted on-screen texts; else take first sentences
  if ($caption) {
    try {
      $q = [System.Text.RegularExpressions.Regex]::Matches($caption, '"([^"]{4,80})"') | ForEach-Object { $_.Groups[1].Value.Trim() }
      $q = $q | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -Unique
      if ($q -and $q.Count -gt 0) {
        $doc.salient = @($q | Select-Object -First 3)
      } else {
        $sentences = $caption -split '[.!?]' | Where-Object { $_.Trim().Length -gt 10 }
        $doc.salient = @($sentences | Select-Object -First 3 | ForEach-Object { $_.Trim() })
      }
    } catch {
      $sentences = $caption -split '[.!?]' | Where-Object { $_.Trim().Length -gt 10 }
      $doc.salient = @($sentences | Select-Object -First 3 | ForEach-Object { $_.Trim() })
    }
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

Write-Host "[VisionProbe] Starting single-shot mode: 1 screenshot every ${BurstIntervalSec}s"
Write-Host "[VisionProbe] Keeping last ${KeepFramesSec}s of frames"
if ($VisionModelPath -match 'llava') {
  if ($VisionMmproj -and (Test-Path $VisionMmproj)) {
    Write-Host "[VisionProbe] Model: $VisionModelPath (LLaVA; mmproj present)"
  } elseif ($VisionHf) {
    Write-Host "[VisionProbe] Model: hf=$VisionHf (LLaVA; will auto-download projector if needed)"
  } else {
    Write-Host "[VisionProbe] Model: $VisionModelPath (LLaVA; mmproj missing)"
  }
} else {
  Write-Host "[VisionProbe] Model: $VisionModelPath (no projector required)"
}

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




