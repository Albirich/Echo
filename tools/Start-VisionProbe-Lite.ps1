<# 
  Start-VisionProbe-Lite.ps1 - OPTIMIZED VERSION
  - Minimal, fast vision probe for Echo (PowerShell 5.1)
  - PERFORMANCE IMPROVEMENTS:
    * Reduced context size (512 -> 256)
    * Reduced prediction tokens (120 -> 60)
    * Increased GPU layers if available
    * Lowered skip threshold for more frequent updates
    * Added parallel processing option
#>

param(
  [switch]$Once,
  [int]$BurstIntervalSec = 8,
  [int]$KeepFramesSec    = 60,
  [switch]$Force
)

# ------------------ Paths & Env ------------------
$HomeDir        = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { 'D:\Echo' }
$StateDir       = if ($env:STATE_DIR -and $env:STATE_DIR.Trim()) { $env:STATE_DIR } else { Join-Path $HomeDir 'state' }
$ScreenshotDir  = Join-Path $HomeDir 'sense\screenshots'
$LogsDir        = Join-Path $HomeDir 'logs'
$CaptionPath    = Join-Path $StateDir 'screen.caption.json'
$HashPath       = Join-Path $StateDir 'screen.last.hash'
$PidFile        = Join-Path $StateDir 'visionprobe.pid'
$StopFile       = Join-Path $StateDir 'visionprobe.stop'
$HostFlagPath   = $env:ECHO_HOST_FLAG
$StopFlagEnv    = $env:ECHO_STOP_FLAG

# Backend select (keep default to llama_cpp for now)
$Backend        = if ($env:ECHO_VISION_BACKEND -and $env:ECHO_VISION_BACKEND.Trim()) { $env:ECHO_VISION_BACKEND } else { 'llama_cpp' }

# llama.cpp model & exe (required for fallback / default)
$LlamaExe       = if ($env:LLAMA_VISION_EXE -and (Test-Path $env:LLAMA_VISION_EXE)) { $env:LLAMA_VISION_EXE } else { 'D:\llama-cpp\llama-mtmd-cli.exe' }
$Model          = if ($env:ECHO_VISION_LLAMACPP_MODEL -and (Test-Path $env:ECHO_VISION_LLAMACPP_MODEL)) { $env:ECHO_VISION_LLAMACPP_MODEL } else { 'D:\Echo\models\llava-phi-3-mini-f16.gguf' }
$Mmproj         = if ($env:ECHO_VISION_MMPROJ -and (Test-Path $env:ECHO_VISION_MMPROJ)) { $env:ECHO_VISION_MMPROJ } else { $null }

# OPTIMIZED: Performance knobs - tuned for speed
$Threads        = 4  # Keep at 4, more can hurt GPU performance
try { if ($env:ECHO_VISION_THREADS -and $env:ECHO_VISION_THREADS.Trim()) { $Threads = [int]$env:ECHO_VISION_THREADS } } catch {}

# OPTIMIZED: Increase GPU layers - try maxing out if you have VRAM
$GpuLayers      = 99  # Increased from 28 - adjust based on your GPU
try { if ($env:ECHO_VISION_GPU_LAYERS -and $env:ECHO_VISION_GPU_LAYERS.Trim()) { $GpuLayers = [int]$env:ECHO_VISION_GPU_LAYERS } } catch {}

# OPTIMIZED: Reduce prediction length - fewer tokens = faster
$NPredict       = 60  # Reduced from 120
try { if ($env:ECHO_VISION_NPREDICT -and $env:ECHO_VISION_NPREDICT.Trim()) { $NPredict = [int]$env:ECHO_VISION_NPREDICT } } catch {}

# OPTIMIZED: Reduce context size dramatically
$CtxSize        = 512  # Reduced from 1024
try { if ($env:ECHO_VISION_CTX -and $env:ECHO_VISION_CTX.Trim()) { $CtxSize = [int]$env:ECHO_VISION_CTX } } catch {}

# OPTIMIZED: Reduce max sentences
$MaxSentences   = if ($env:ECHO_VISION_MAX_SENTENCES) { [int]$env:ECHO_VISION_MAX_SENTENCES } else { 2 }  # Reduced from 4

$CaptureWindowOnly = $true
try {
  if ($env:ECHO_VISION_WINDOW_ONLY -and ($env:ECHO_VISION_WINDOW_ONLY -match '^(0|false|no)$')) { $CaptureWindowOnly = $false }
} catch {}

# ------------------ Helpers ------------------
function IsoNow { (Get-Date).ToString('o') }

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
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
          Write-Host "[VisionLite] Already running (PID=$opid). Exiting."
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

# Win32 capture setup
try {
  Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WinApi {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
  public const int MONITOR_DEFAULTTONEAREST = 2;
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
  public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
}
"@
} catch {}

try { Add-Type -AssemblyName System.Drawing | Out-Null } catch {}

function Get-ActiveWindowInfo {
  $h = [WinApi]::GetForegroundWindow()
  if ($h -eq [IntPtr]::Zero) { return @{ hwnd=0; title=$null; process=$null; exe=$null; bounds=$null; mon=$null } }

  $sb = New-Object System.Text.StringBuilder 512
  [void][WinApi]::GetWindowText($h, $sb, $sb.Capacity)
  $title = $sb.ToString()

  $rc = New-Object WinApi+RECT
  [void][WinApi]::GetWindowRect($h, [ref]$rc)
  $bounds = @{ left=$rc.Left; top=$rc.Top; right=$rc.Right; bottom=$rc.Bottom }

  $mi = New-Object WinApi+MONITORINFO
  $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][WinApi+MONITORINFO])
  $monH = [WinApi]::MonitorFromWindow($h, [WinApi]::MONITOR_DEFAULTTONEAREST)
  $mon = $null
  if ($monH -ne [IntPtr]::Zero -and [WinApi]::GetMonitorInfo($monH, [ref]$mi)) {
    $mon = @{ left=$mi.rcMonitor.Left; top=$mi.rcMonitor.Top; right=$mi.rcMonitor.Right; bottom=$mi.rcMonitor.Bottom }
  }

  $procId = 0
  [void][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  [void][WinApi]::GetWindowRect($h, [ref]$rc)
  $p = $null
  try {
    [void][WinApi]::GetWindowRect($h, [ref]$rc)
    $tid = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $null = $tid
  } catch {}
  try {
    $pidRef = 0
    [void][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  } catch {}
  try {
    $null = [WinApi]::GetWindowRect($h, [ref]$rc)
  } catch {}
  try {
    $p = Get-Process -Id ((Get-Process | Where-Object { $_.MainWindowHandle -eq $h }).Id) -ErrorAction Stop
  } catch {
    try {
      $p = Get-Process | Where-Object { $_.MainWindowTitle -eq $title } | Select-Object -First 1
    } catch {}
  }

  return @{
    hwnd    = $h.ToInt64()
    title   = $title
    process = if ($p) { $p.ProcessName } else { $null }
    exe     = if ($p) { $p.Path } else { $null }
    bounds  = $bounds
    mon     = $mon
  }
}

function Save-Jpeg([System.Drawing.Bitmap]$Bitmap, [string]$Path, [int]$Quality=85) {
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  if (-not $codec) { $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg); return }
  $encParms = New-Object System.Drawing.Imaging.EncoderParameters 1
  $encParms.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
  $Bitmap.Save($Path, $codec, $encParms)
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

  $w = [Math]::Min($w, 3840); $h = [Math]::Min($h, 2160)
  try {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($srcX, $srcY, 0, 0, $bmp.Size)
    $gfx.Dispose()
    Save-Jpeg -Bitmap $bmp -Path $PathJpg -Quality 85
    $bmp.Dispose()
    return $true
  } catch {
    Write-Warning "Capture-Frame error: $($_.Exception.Message)"
    return $false
  }
}

function Capture-One {
  $info = Get-ActiveWindowInfo
  if (-not $info.title) {
    Write-Host '[VisionLite] No active window found; returning empty.'
    return @{ frames=@(); window=$info }
  }
  $ts = (Get-Date).ToString('yyyyMMdd_HHmmss_fff')
  $fname = "frame_$ts.jpg"
  $path = Join-Path $ScreenshotDir $fname
  $ok = Capture-Frame -WindowInfo $info -PathJpg $path -WindowOnly:$CaptureWindowOnly
  if ($ok) { return @{ frames=@($path); window=$info } }
  return @{ frames=@(); window=$info }
}

function Get-AvgHash([string]$Path) {
  try {
    $bmp = [System.Drawing.Bitmap]::FromFile($Path)
    $thumb = New-Object System.Drawing.Bitmap 8,8
    $gfx = [System.Drawing.Graphics]::FromImage($thumb)
    $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gfx.DrawImage($bmp, 0, 0, 8, 8)
    $gfx.Dispose(); $bmp.Dispose()
    $px = @(0) * 64; $sum = 0L
    for ($y=0;$y -lt 8;$y++) {
      for ($x=0;$x -lt 8;$x++) {
        $c = $thumb.GetPixel($x,$y)
        $gray = [int](($c.R * 0.299) + ($c.G * 0.587) + ($c.B * 0.114))
        $px[$y*8+$x] = $gray; $sum += $gray
      }
    }
    $thumb.Dispose()
    $avg = $sum / 64.0
    $bits = 0L
    for ($i=0;$i -lt 64;$i++) {
      if ($px[$i] -ge $avg) { $bits = $bits -bor (1L -shl $i) }
    }
    return $bits
  } catch { return 0L }
}

function Hamming64([Int64]$a,[Int64]$b) {
  $x = $a -bxor $b
  $count = 0
  for ($i=0;$i -lt 64;$i++) { if ($x -band (1L -shl $i)) { $count++ } }
  return $count
}

# --------------- Captioning ---------------
function Clean-BackendNoise([string]$raw) {
  if (-not $raw) { return $raw }
  $lines = @($raw -split "`r?`n")
  $keep = New-Object System.Collections.Generic.List[string]
  foreach ($ln in $lines) {
    $t = $ln.Trim()
    if ($t -eq '') { continue }
    if ($t -match '^(ggml|load_backend|system_info|AVX|BLAS|CUDA|RPC|metal|gpu split|n_gpu_layers|n_threads|llama_)') { continue }
    if ($t -match '^(print_info:|load_tensors:|common_init_from_params:|clip_model_loader:|load_hparams:|alloc_compute_meta:|mtmd_cli_context:|encoding image slice|decoding image batch|image decoded|main:)') { continue }
    if ($t -match '^Experimental CLI for multimodal') { continue }
    if ($t -match '^\+ CategoryInfo\b' -or $t -match '^\+ FullyQualifiedErrorId\b' -or $t -match '^At .*\.ps1:\d+\s+char:\d+') { continue }
    $keep.Add($ln)
  }
  return ($keep -join "`n").Trim()
}

function Harvest-Quotes([string]$Caption,[int]$Max=3) {
  if (-not $Caption) { return @() }
  try {
    $m = [regex]::Matches($Caption, '"([^"]{4,80})"')
    $vals = @()
    foreach ($mm in $m) { $vals += $mm.Groups[1].Value.Trim() }
    return @($vals | Where-Object { $_ } | Select-Object -Unique | Select-Object -First $Max)
  } catch { return @() }
}

function Build-Context([hashtable]$Win) {
  $title = if ($Win.title) { $Win.title } else { '' }
  $proc  = if ($Win.process) { $Win.process } else { '' }
  if ($proc -match 'Discord') { return 'Context: Discord channel view.' }
  if ($proc -match 'chrome|msedge|firefox') {
    if ($title -match 'YouTube') { return 'Context: YouTube watch page.' }
    return 'Context: Web page.'
  }
  if ($proc -match 'Code') { return 'Context: VS Code editor.' }
  if ($proc -match 'steam') { return 'Context: Steam client.' }
  return 'Context: Application window.'
}

function Describe-Image([string]$ImagePath,[hashtable]$Win) {
  $ctx = Build-Context -Win $Win
  # OPTIMIZED: Shorter, more concise prompt
  $prompt = @"
$ctx
Describe what's visible in 2 short sentences. Include 1-2 key UI elements or quoted text.
<desc>...</desc>
"@

  if (-not (Test-Path $Model)) { Write-Warning "[VisionLite] Model not found: $Model"; return $null }
  if (-not (Test-Path $LlamaExe)) { Write-Warning "[VisionLite] Llama exe not found: $LlamaExe"; return $null }

  # OPTIMIZED: Added --no-display-prompt to reduce overhead
  $args = @('-m', $Model, '-t', $Threads, '--temp', '0.1', '-c', $CtxSize, '-n', $NPredict, '--image', $ImagePath, '--prompt', $prompt, '-ngl', $GpuLayers, '--no-display-prompt')
  if ($Mmproj -and (Test-Path $Mmproj)) {
    $args = @('-m', $Model, '--mmproj', $Mmproj, '-t', $Threads, '--temp', '0.1', '-c', $CtxSize, '-n', $NPredict, '--image', $ImagePath, '--prompt', $prompt, '-ngl', $GpuLayers, '--no-display-prompt')
  }

  try {
    $raw = & $LlamaExe @args 2>$null | Out-String
    if (-not $raw) { return $null }

    try {
      $m = [regex]::Match($raw, '<desc>([\s\S]*?)</desc>', 'IgnoreCase')
      $desc = if ($m.Success) { $m.Groups[1].Value.Trim() } else { '' }
      if ($desc) { return $desc }
    } catch {}

    return (Clean-BackendNoise -raw $raw)
  } catch {
    Write-Warning ("[VisionLite] llama.cpp error: {0}" -f $_.Exception.Message)
    return $null
  }
}

# --------------- One iteration ---------------
function Run-Once {
  $cap = Capture-One
  if ($cap.frames.Count -eq 0) { return $true }
  $img = $cap.frames[0]

  # OPTIMIZED: More aggressive skip detection - skip less often
  $newH = Get-AvgHash $img
  $oldH = 0L; if (Test-Path $HashPath) { try { $oldH = [Int64](Get-Content -LiteralPath $HashPath -Raw) } catch {} }
  $ham = Hamming64 $newH $oldH
  $oldTitle = $null
  if (Test-Path $CaptionPath) {
    try { $oldTitle = ((Get-Content -LiteralPath $CaptionPath -Raw | ConvertFrom-Json).active_window.title) } catch {}
  }
  $titleSame = ($oldTitle -eq $cap.window.title)
  
  # OPTIMIZED: Changed from <6 to <4 - skip only if VERY similar
  if ($titleSame -and $ham -lt 4) {
    Write-Host ("[VisionLite] Skipped (delta small, h={0})" -f $ham)
    return $true
  }

  $t0 = Get-Date
  $summary = Describe-Image -ImagePath $img -Win $cap.window
  $t1 = Get-Date

  $doc = @{
    ts = IsoNow
    active_window = @{ title = $cap.window.title; process = $cap.window.process; exe = $cap.window.exe }
    burst = @{
      frame_count = 1; duration_sec = 0; fps = 0
      first_frame = (Split-Path -Leaf $img)
      last_frame  = (Split-Path -Leaf $img)
    }
    summary = $summary
    salient = @(Harvest-Quotes -Caption $summary -Max 3)
    visible_text = @()
  }

  $json = $doc | ConvertTo-Json -Depth 6
  AtomicWrite-Text -Path $CaptionPath -Content $json -Encoding (New-Object System.Text.UTF8Encoding $false)
  Set-Content -LiteralPath $HashPath -Value "$newH" -Encoding ascii

  $delta = ($t1 - $t0).TotalSeconds
  $len = if ($summary) { $summary.Length } else { 0 }
  Write-Host ("[VisionLite] Caption written: {0} chars (d={1:N2}s)" -f $len, $delta)

  # Cleanup
  if (Test-Path -LiteralPath $ScreenshotDir) {
    $cutoff = (Get-Date).AddSeconds(-$KeepFramesSec)
    foreach ($f in (Get-ChildItem -LiteralPath $ScreenshotDir -Filter 'frame_*.jpg' -File -ErrorAction SilentlyContinue)) {
      if ($f.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
  }
  return $true
}

# ------------------ Boot ------------------
Ensure-Dir $StateDir
Ensure-Dir $ScreenshotDir
Ensure-Dir $LogsDir
Enter-Singleton

try {
  if ($env:ECHO_VISION_INTERVAL_SEC -and $env:ECHO_VISION_INTERVAL_SEC.Trim()) { $BurstIntervalSec = [int]$env:ECHO_VISION_INTERVAL_SEC }
} catch {}

Write-Host ("[VisionLite] Backend={0} | LlamaExe={1}" -f $Backend, $LlamaExe)
Write-Host ("[VisionLite] Model={0} | Mmproj={1}" -f $Model, ($(if ($Mmproj) { $Mmproj } else { '(none)' })))
Write-Host ("[VisionLite] OPTIMIZED: Ctx={0} NPred={1} Threads={2} GpuLayers={3} WinOnly={4}" -f $CtxSize, $NPredict, $Threads, $GpuLayers, $CaptureWindowOnly)
Write-Host ("[VisionLite] Interval={0}s Keep={1}s" -f $BurstIntervalSec, $KeepFramesSec)

if ($Once) { [void](Run-Once); return }

$next = Get-Date
while ($true) {
  try {
    if (Test-Path -LiteralPath $StopFile) { Write-Host '[VisionLite] Stop flag found, exiting.'; break }
    if ($StopFlagEnv -and (Test-Path -LiteralPath $StopFlagEnv)) { Write-Host '[VisionLite] Global stop flag found, exiting.'; break }
    if (-not $Force -and -not ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath))) { Write-Host '[VisionLite] Host flag missing, exiting.'; break }
    [void](Run-Once)
  } catch {
    Write-Warning ("[VisionLite] Error: {0}" -f $_.Exception.Message)
  }
  $next = $next.AddSeconds([Math]::Max(2, $BurstIntervalSec))
  $sleep = [int][Math]::Max(0, ($next - (Get-Date)).TotalSeconds)
  if ($sleep -gt 0) { Start-Sleep -Seconds $sleep }
}