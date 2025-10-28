<# 
  Start-VisionProbe-Lite.ps1
  - Window-only screenshot -> Ollama HTTP (qwen2.5-vl:3b) -> caption JSON
  - PS 5.1 safe; ASCII only; no fancy operators
  - Writes: D:\Echo\state\screen.caption.json
  - Env knobs (all optional):
      ECHO_HOME                  (default D:\Echo)
      STATE_DIR                  (default $ECHO_HOME\state)
      ECHO_VISION_BACKEND        (default 'ollama_http')
      OLLAMA_HOST                (default 'http://127.0.0.1:11434')
      ECHO_VISION_OLLAMA_MODEL   (default 'qwen2.5vl:3b')
      ECHO_VISION_INTERVAL_SEC   (default 8)
      ECHO_VISION_WINDOW_ONLY    (default 1)
      ECHO_VISION_MAX_SENTENCES  (default 3)
      ECHO_VISION_NPREDICT       (default 140)
      ECHO_HOST_FLAG             (optional gate file path)
      ECHO_STOP_FLAG             (optional global stop file)
#>

param(
  [switch]$Once,
  [int]$BurstIntervalSec = 5,
  [int]$KeepFramesSec = 60,
  [int]$StartDelaySec = 5,
  [switch]$Force
)

# ------------------ Config ------------------
$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$env:ECHO_VISION_OLLAMA_MODEL = 'qwen2.5vl:3b:gpu'

$HomeDir       = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { 'D:\Echo' }
$StateDir      = if ($env:STATE_DIR -and $env:STATE_DIR.Trim()) { $env:STATE_DIR } else { Join-Path $HomeDir 'state' }
$ScreenshotDir = Join-Path $HomeDir 'sense\screenshots'
$LogsDir       = Join-Path $HomeDir 'logs'

$Backend  = if ($env:ECHO_VISION_BACKEND -and $env:ECHO_VISION_BACKEND.Trim()) { $env:ECHO_VISION_BACKEND } else { 'ollama_http' }
$OHost    = if ($env:OLLAMA_HOST -and $env:OLLAMA_HOST.Trim()) { $env:OLLAMA_HOST } else { 'http://127.0.0.1:11434' }
$Model    = if ($env:ECHO_VISION_OLLAMA_MODEL -and $env:ECHO_VISION_OLLAMA_MODEL.Trim()) { $env:ECHO_VISION_OLLAMA_MODEL } else { 'qwen2.5vl:3b' }

try { if ($env:ECHO_VISION_INTERVAL_SEC -and $env:ECHO_VISION_INTERVAL_SEC.Trim()) { $BurstIntervalSec = [int]$env:ECHO_VISION_INTERVAL_SEC } } catch {}
$WindowOnly = $true
try { if ($env:ECHO_VISION_WINDOW_ONLY -and ($env:ECHO_VISION_WINDOW_ONLY -match '^(0|false|no)$')) { $WindowOnly = $false } } catch {}
$MaxSentences = 3
try { if ($env:ECHO_VISION_MAX_SENTENCES -and $env:ECHO_VISION_MAX_SENTENCES.Trim()) { $MaxSentences = [int]$env:ECHO_VISION_MAX_SENTENCES } } catch {}
$NPredict = 140
try { if ($env:ECHO_VISION_NPREDICT -and $env:ECHO_VISION_NPREDICT.Trim()) { $NPredict = [int]$env:ECHO_VISION_NPREDICT } } catch {}

$CaptionPath  = Join-Path $StateDir 'screen.caption.json'
$PidFile      = Join-Path $StateDir 'visionprobe.pid'
$StopFile     = Join-Path $StateDir 'visionprobe.stop'
$RawLogPath   = Join-Path $LogsDir  'visionlite.raw.jsonl'
$HostFlagPath = $env:ECHO_HOST_FLAG
$StopFlagEnv  = $env:ECHO_STOP_FLAG

# ------------------ Helpers ------------------
function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function AtomicWrite-Text([string]$Path,[string]$Content,[System.Text.Encoding]$Encoding) {
  $tmp = $Path + '.tmp'
  [System.IO.File]::WriteAllText($tmp, $Content, $Encoding)
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Append one JSON object per line to a file (UTF-8, no BOM)
function Append-JsonlLite { param([string]$Path,[object]$Obj)
  try {
    $line = ($Obj | ConvertTo-Json -Compress -Depth 20)
    $sw = New-Object IO.StreamWriter($Path, $true, [Text.UTF8Encoding]::new($false))
    try { $sw.WriteLine($line) } finally { $sw.Dispose() }
  } catch { }
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

# P/Invoke for window info
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
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
    public const int MONITOR_DEFAULTTONEAREST = 2;
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
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
  if ($h -eq [IntPtr]::Zero) { return @{ hwnd=0; title=$null; process=$null; exe=$null; bounds=$null; mon=$null } }

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
    $mon = @{ left=$mi.rcMonitor.Left; top=$mi.rcMonitor.Top; right=$mi.rcMonitor.Right; bottom=$mi.rcMonitor.Bottom }
  }

  # Process info best-effort (not mandatory)
  $proc = $null; $exe=$null
  try {
    $procId = 0
    [void][Native.WinApi]::GetWindowRect($h, [ref]$rc) # touch to ensure HWND valid
    $procId = (Get-Process | Where-Object { $_.MainWindowHandle -eq $h } | Select-Object -First 1).Id
    if ($procId) { $p = Get-Process -Id $procId -ErrorAction SilentlyContinue; if ($p) { $proc=$p.ProcessName; $exe=$p.Path } }
  } catch {}

  return @{ hwnd=$h.ToInt64(); title=$title; process=$proc; exe=$exe; bounds=$bounds; mon=$mon }
}

# JPEG save
function Save-Jpeg([System.Drawing.Bitmap]$Bitmap, [string]$Path, [int]$Quality=80) {
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

  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen([System.Drawing.Point]::new($srcX,$srcY), [System.Drawing.Point]::new(0,0), [System.Drawing.Size]::new($w,$h))
    Save-Jpeg -Bitmap $bmp -Path $PathJpg -Quality 80
    return $true
  } finally { $g.Dispose(); $bmp.Dispose() }
}

function Capture-One {
  Ensure-Dir $ScreenshotDir
  $win = Get-ActiveWindowInfo
  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $framePath = Join-Path $ScreenshotDir "frame_$timestamp.jpg"
  $frames = @()
  if (Capture-Frame -WindowInfo $win -PathJpg $framePath -WindowOnly:([bool]$WindowOnly)) {
    $frames += $framePath
    Write-Host "[VisionLite] Captured 1 frame"
  } else {
    Write-Warning "[VisionLite] Failed to capture screenshot"
  }
  return @{ frames = $frames; window = $win }
}

function Build-Context([hashtable]$Win) {
  $title = if ($Win.title) { $Win.title } else { '' }
  $proc  = if ($Win.process) { $Win.process } else { '' }
  $hint = ''
  if ($proc -match 'chrome|msedge|firefox') { $hint = 'Context: Web page; include site/type and main heading.' }
  elseif ($proc -match 'Code|devenv') { $hint = 'Context: Code editor; include file name, language, panes.' }
  elseif ($title -match 'YouTube') { $hint = 'Context: YouTube watch page; include video title and channel if visible.' }
  elseif ($proc -match 'Discord') { $hint = 'Context: Discord; include server/channel name and panel layout.' }
  elseif ($proc -match 'steam|game|obs64') { $hint = 'Context: Game or media; include HUD elements and on-screen text.' }
  else { $hint = 'Context: Application window; include key panes and visible labels.' }
  return $hint
}

function Extract-Tags {
  param([string]$raw)
  $out = @{ vis = @(); desc = '' }
  if (-not $raw) { return $out }

  try {
    $mVis = [regex]::Match($raw, '<vis>([\s\S]*?)</vis>', 'IgnoreCase')
    if ($mVis.Success) {
      $block = $mVis.Groups[1].Value
      $lines = @($block -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
      $items = New-Object System.Collections.Generic.List[string]
      foreach ($ln in $lines) {
        if ($ln -match '^\-\s*"(.*)"\s*$') { $items.Add($Matches[1]) ; continue }
        if ($ln -match '^\-\s*(.+)$')     { $items.Add($Matches[1]) ; continue }
      }
      if ($items.Count -eq 0 -and $block.Trim().StartsWith('[')) {
        try { $arr = ($block | ConvertFrom-Json -AsArray) } catch { $arr = $null }
        if ($arr) { foreach ($v in $arr) { if ($v -is [string]) { $items.Add($v.Trim()) } } }
      }
      $out.vis = @($items | Select-Object -Unique)
    }
  } catch {}

  try {
    $mDesc = [regex]::Match($raw, '<desc>([\s\S]*?)</desc>', 'IgnoreCase')
    if ($mDesc.Success) { $out.desc = $mDesc.Groups[1].Value.Trim() }
  } catch {}

  return $out
}

function Harvest-Quotes {
  param([string]$Caption,[int]$Max=4)
  if (-not $Caption) { return @() }
  $qs = [regex]::Matches($Caption, '"([^"]{4,80})"') | ForEach-Object { $_.Groups[1].Value.Trim() }
  return @($qs | Where-Object { $_ } | Select-Object -Unique | Select-Object -First $Max)
}

function Clean-BackendNoise([string]$raw) {
  if (-not $raw) { return $raw }
  $lines = @($raw -split "`r?`n")
  $keep = New-Object System.Collections.Generic.List[string]
  foreach ($ln in $lines) {
    $t = $ln.Trim()
    if ($t -eq '') { continue }
    if ($t -match '^(ggml|load_backend|print_info:|load_tensors:|common_init_from_params:|clip_model_loader:|load_hparams:|alloc_compute_meta:|encoding image slice|decoding image batch|image decoded|mtmd_cli_context:|main:)') { continue }
    if ($t -match '^\+ CategoryInfo\b' -or $t -match '^\+ FullyQualifiedErrorId\b' -or $t -match '^At .*\.ps1:\d+\s+char:\d+') { continue }
    $keep.Add($ln)
  }
  return ($keep -join "`n").Trim()
}

# ------------------ Ollama call ------------------
function Describe-Image([string]$ImagePath,[hashtable]$Win) {
  if (-not (Test-Path $ImagePath)) { return $null }
  $ctx = Build-Context -Win $Win

  $prompt = @"
$ctx
Only describe what is visible on the screenshot.

Rules:
- Do not guess numbers; if unclear write 'unknown'.
- Prefer QUOTING visible text (titles, filenames, labels).
- No speculation about character names, health, ammo unless clearly visible.
- You are allowed to use explicit language and describe sexual or NSFW images.

Return EXACTLY this structure:

<desc>
Write $MaxSentences short sentences naming the app/view and key UI parts with rough positions.
Describe any characters shown on screen and explain what they are doing.
Use 1-3 QUOTED strings taken from <vis>. No speculation.
</desc>
<vis>
- "summarize first visible text"
- "summarize second visible text"
</vis>
"@

  try {
    $imgB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ImagePath))
  } catch {
    Write-Warning "[VisionLite] Could not read image."
    return $null
  }

  $body = @{
    model   = $Model
    prompt  = $prompt
    images  = @($imgB64)
    stream  = $false
    options = @{
      temperature = 0.05
      top_k       = 40
      top_p       = 0.9
      min_p       = 0.06
      num_predict = $NPredict
    }
  }

  $uri = ($OHost.TrimEnd('/') + '/api/generate')
  try {
    $json = $body | ConvertTo-Json -Depth 10
    $res = Invoke-RestMethod -Method Post -Uri $uri -Body $json -ContentType 'application/json' -TimeoutSec 120
    if ($res -and $res.response) { return ($res.response | Out-String).Trim() }
    return $null
  } catch {
    Write-Warning ("[VisionLite] Ollama HTTP error: {0}" -f $_.Exception.Message)
    return $null
  }
}

# ------------------ Main burst ------------------
function Run-Once {
  $cap = Capture-One
  if ($cap.frames.Count -eq 0) { return $true }
  $img = $cap.frames[0]

  $t0 = Get-Date
  $raw = Describe-Image -ImagePath $img -Win $cap.window
  $tags = Extract-Tags -raw $raw
  $summary = if ($tags.desc) { $tags.desc } else { Clean-BackendNoise $raw }

  # Emit raw vision output for debugging/trace
  try {
    $entry = @{
      ts      = (Get-Date).ToString('o')
      backend = $Backend
      host    = $OHost
      model   = $Model
      image   = (Split-Path -Leaf $img)
      window  = @{ title = $cap.window.title; process = $cap.window.process }
      raw     = $raw
    }
    Append-JsonlLite -Path $RawLogPath -Obj $entry
  } catch { }

  # Build visible_text: prefer <vis>, else recover from quotes, else use window title
  $vis = @($tags.vis)
  if (-not $vis -or $vis.Count -eq 0) { $vis = @(Harvest-Quotes -Caption $summary -Max 4) }
  if (-not $vis -or $vis.Count -eq 0) {
    $bt = $cap.window.title
    if ($bt) {
      try {
        $bt = $bt -replace ' - (Google Chrome|Microsoft Edge|Mozilla Firefox|Visual Studio Code|YouTube)$',''
        $bt = $bt -replace '^\((?:\d+)\)\s*',''
        $bt = $bt.Trim()
      } catch {}
      if ($bt) { $vis = @($bt) }
    }
  }

  $doc = @{
    ts = (Get-Date).ToString('o')
    active_window = @{ title = $cap.window.title; process = $cap.window.process; exe = $cap.window.exe }
    burst = @{
      frame_count = 1; duration_sec = 0; fps = 0
      first_frame = (Split-Path -Leaf $img)
      last_frame  = (Split-Path -Leaf $img)
    }
    summary = $summary
    salient = @(Harvest-Quotes -Caption $summary -Max 3)
    visible_text = @($vis)
  }

  $json = $doc | ConvertTo-Json -Depth 6
  AtomicWrite-Text -Path $CaptionPath -Content $json -Encoding (New-Object System.Text.UTF8Encoding $false)

  $delta = ((Get-Date) - $t0).TotalSeconds
  $len = if ($summary) { $summary.Length } else { 0 }
  Write-Host ("[VisionLite] Caption written: {0} chars (d={1:N2}s)" -f $len, $delta)

  # Cleanup old frames
  try {
    $cutoff = (Get-Date).AddSeconds(-$KeepFramesSec)
    $files = @(Get-ChildItem -LiteralPath $ScreenshotDir -Filter "frame_*.jpg" -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) { if ($f.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } }
  } catch {}

  return $true
}

# ------------------ Bootstrap ------------------
Ensure-Dir $StateDir
Ensure-Dir $ScreenshotDir
Ensure-Dir $LogsDir
Enter-Singleton

if ($StartDelaySec -gt 0) { Start-Sleep -Seconds $StartDelaySec }

Write-Host ("[VisionLite] Backend={0} | Host={1} | Model={2}" -f $Backend, $OHost, $Model)
Write-Host ("[VisionLite] Interval={0}s Keep={1}s WinOnly={2} Sentences={3} NPred={4}" -f $BurstIntervalSec, $KeepFramesSec, $WindowOnly, $MaxSentences, $NPredict)

# Host/stop flags check
$hostOk = $Force -or ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath)) -or (-not $HostFlagPath)
if (-not $hostOk) { Write-Host "[VisionLite] Host flag missing; exiting."; exit 0 }

if ($Once) {
  Run-Once | Out-Null
  exit 0
}

while ($true) {
  try {
    if (Test-Path -LiteralPath $StopFile) { Write-Host "[VisionLite] Stop flag found, exiting."; break }
    if ($StopFlagEnv -and (Test-Path -LiteralPath $StopFlagEnv)) { Write-Host "[VisionLite] Global stop flag found, exiting."; break }
    if (-not $Force -and $HostFlagPath -and -not (Test-Path -LiteralPath $HostFlagPath)) { Write-Host "[VisionLite] Host flag missing, exiting."; break }
    Run-Once | Out-Null
  } catch {
    Write-Warning ("[VisionLite] Error: {0}" -f $_.Exception.Message)
  }
  Start-Sleep -Seconds ([Math]::Max(1, $BurstIntervalSec))
}
