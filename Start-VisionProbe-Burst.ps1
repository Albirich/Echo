<#
  Start-VisionProbe-Burst.ps1
  - Single-screenshot probe in a fixed-interval loop
  - GPU-adaptive llama.cpp call (caps CPU threads; adapts -ngl to avoid CPU fallback)
  - Uses Start-LocalLLM.ps1 if present (for correct chat/vision templating)
  - Scrubs llama/ggml banners from model output so only caption text is saved
  - JSON: summary, salient, visible_text, active_window, burst meta

  Env knobs (examples):
    ECHO_VISION_INTERVAL_SEC = 10
    ECHO_VISION_WINDOW_ONLY  = 1   (set 0/false to capture full monitor)
    ECHO_VISION_THREADS      = 4
    ECHO_VISION_GPU_LAYERS   = 35  (try 20–40 for 3B–4B models; 999 = all)
    ECHO_VISION_SENTENCES    = 3
    ECHO_VISION_NPREDICT     = 160
    ECHO_VISION_MAX_CHARS    = 700
    ECHO_VISION_SKIP_OCR     = 1   (0 to enable OCR functions if you add them)
    ECHO_VISION_LLAMACPP_MODEL / ECHO_LLAMACPP_VISION_MODEL / VISION_MODEL
    LLAMA_VISION_EXE (e.g., D:\llama-cpp\llama-mtmd-cli.exe)
    ECHO_VISION_MMPROJ (override mmproj path for LLaVA)
    ECHO_HOME, STATE_DIR
#>

param(
  [switch]$Once,
  [int]$BurstIntervalSec = 10,
  [int]$KeepFramesSec    = 60,
  [switch]$Force
)

# ------------------ Paths & Config ------------------
$HomeDir       = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { 'D:\Echo' }
$StateDir      = if ($env:STATE_DIR -and $env:STATE_DIR.Trim()) { $env:STATE_DIR } else { Join-Path $HomeDir 'state' }
$ScreenshotDir = Join-Path $HomeDir 'sense\screenshots'
$LogsDir       = Join-Path $HomeDir 'logs'

# llama.cpp executable preference
$LlamaExe = $null
if ($env:LLAMA_VISION_EXE -and (Test-Path $env:LLAMA_VISION_EXE)) { $LlamaExe = $env:LLAMA_VISION_EXE }
elseif (Test-Path 'D:\llama-cpp\llama-mtmd-cli.exe') { $LlamaExe = 'D:\llama-cpp\llama-mtmd-cli.exe' }
elseif ($env:LLAMA_EXE -and (Test-Path $env:LLAMA_EXE)) { $LlamaExe = $env:LLAMA_EXE }
else { $LlamaExe = 'D:\llama-cpp\llama-cli.exe' }

# Model (prefer LLaVA Phi-3 mini f16 by default)
$Model = $null
if     ($env:ECHO_VISION_LLAMACPP_MODEL -and (Test-Path $env:ECHO_VISION_LLAMACPP_MODEL)) { $Model = $env:ECHO_VISION_LLAMACPP_MODEL }
elseif ($env:ECHO_LLAMACPP_VISION_MODEL -and (Test-Path $env:ECHO_LLAMACPP_VISION_MODEL)) { $Model = $env:ECHO_LLAMACPP_VISION_MODEL }
elseif ($env:VISION_MODEL -and (Test-Path $env:VISION_MODEL)) { $Model = $env:VISION_MODEL }
elseif (Test-Path (Join-Path $HomeDir 'models\llava-phi-3-mini-f16.gguf')) { $Model = (Join-Path $HomeDir 'models\llava-phi-3-mini-f16.gguf') }
else { $Model = 'D:\Echo\models\llava-phi-3-mini-f16.gguf' }

# mmproj for LLaVA (ignore placeholders like <PATH\TO\mmproj>)
$Mmproj = $null
if ($env:ECHO_VISION_MMPROJ -and (Test-Path $env:ECHO_VISION_MMPROJ)) { $Mmproj = $env:ECHO_VISION_MMPROJ }
else {
  if ($Model -and (Split-Path -Leaf $Model) -match 'llava' -and (Test-Path $Model)) {
    $modelDir = Split-Path -Parent $Model
    $cand1 = Join-Path $modelDir 'llava-phi-3-mini-mmproj-f16.gguf'
    $cand2 = Join-Path (Join-Path $HomeDir 'models') 'llava-phi-3-mini-mmproj-f16.gguf'
    foreach ($c in @($cand1, $cand2)) { if (Test-Path $c) { $Mmproj = $c; break } }
  }
}

# Perf knobs
$Threads    = 0; try { if ($env:ECHO_VISION_THREADS -and $env:ECHO_VISION_THREADS.Trim()) { $Threads = [int]$env:ECHO_VISION_THREADS } } catch {}
$NPredict   = 160; try { if ($env:ECHO_VISION_NPREDICT -and $env:ECHO_VISION_NPREDICT.Trim()) { $NPredict = [int]$env:ECHO_VISION_NPREDICT } } catch {}
$CtxSize    = 1536; try { if ($env:ECHO_VISION_CTX -and $env:ECHO_VISION_CTX.Trim()) { $CtxSize = [int]$env:ECHO_VISION_CTX } } catch {}
$GpuLayers  = 35; try { if ($env:ECHO_VISION_GPU_LAYERS -and $env:ECHO_VISION_GPU_LAYERS.Trim()) { $GpuLayers = [int]$env:ECHO_VISION_GPU_LAYERS } } catch {}
$MaxSentences = 3; try { if ($env:ECHO_VISION_SENTENCES -and $env:ECHO_VISION_SENTENCES.Trim()) { $MaxSentences = [int]$env:ECHO_VISION_SENTENCES } } catch {}
$MaxChars     = 700; try { if ($env:ECHO_VISION_MAX_CHARS -and $env:ECHO_VISION_MAX_CHARS.Trim()) { $MaxChars = [int]$env:ECHO_VISION_MAX_CHARS } } catch {}

# OCR skip (you can wire OCR back later)
$SkipOCR = $true; try { if ($env:ECHO_VISION_SKIP_OCR -and ($env:ECHO_VISION_SKIP_OCR -match '^(0|false|no)$')) { $SkipOCR = $false } } catch {}

# Optional interval override via env
try { if ($env:ECHO_VISION_INTERVAL_SEC -and $env:ECHO_VISION_INTERVAL_SEC.Trim()) { $BurstIntervalSec = [int]$env:ECHO_VISION_INTERVAL_SEC } } catch {}

# Capture mode: window-only for speed unless disabled
$CaptureWindowOnly = $true; try { if ($env:ECHO_VISION_WINDOW_ONLY -and ($env:ECHO_VISION_WINDOW_ONLY -match '^(0|false|no)$')) { $CaptureWindowOnly = $false } } catch {}

# Quieter llama logs so we don't get banners into summary
if (-not $env:LLAMA_LOG_LEVEL) { $env:LLAMA_LOG_LEVEL = '40' }  # 40 = warning

$CaptionPath  = Join-Path $StateDir 'screen.caption.json'
$PidFile      = Join-Path $StateDir 'visionprobe.pid'
$StopFile     = Join-Path $StateDir 'visionprobe.stop'
$HostFlagPath = $env:ECHO_HOST_FLAG
$StopFlagEnv  = $env:ECHO_STOP_FLAG

# ------------------ Helpers ------------------
function IsoNow { (Get-Date).ToString('o') }

function Ensure-Dir([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

function AtomicWrite-Text([string]$Path,[string]$Content,[System.Text.Encoding]$Encoding) {
  $tmp = $Path + '.tmp'
  [System.IO.File]::WriteAllText($tmp, $Content, $Encoding)
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Save-Jpeg([System.Drawing.Bitmap]$Bitmap, [string]$Path, [int]$Quality=80) {
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
      if ($old -match '^[0-9]+$') {
        $opid = [int]$old
        if (Get-Process -Id $opid -ErrorAction SilentlyContinue) {
          Write-Host "[VisionProbe] Already running (PID=$opid). Exiting."
          exit 0
        }
      }
    } catch {}
  }
  $PID | Out-File -LiteralPath $PidFile -Encoding ascii -Force
  Register-EngineEvent PowerShell.Exiting -Action { try { Remove-Item -LiteralPath $using:PidFile -Force -ErrorAction SilentlyContinue } catch {} } | Out-Null
}

# C# shim for active window & bounds
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

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  }
}
"@
} catch {}
try { Add-Type -AssemblyName System.Drawing | Out-Null } catch {}

function Get-ActiveWindowInfo {
  $h = [Native.WinApi]::GetForegroundWindow()
  if ($h -eq [IntPtr]::Zero) { return @{ hwnd=0; title=$null; process=$null; exe=$null; bounds=$null } }

  $sb = New-Object System.Text.StringBuilder 512
  [void][Native.WinApi]::GetWindowText($h, $sb, $sb.Capacity)
  $title = $sb.ToString()

  $rc = New-Object Native.WinApi+RECT
  [void][Native.WinApi]::GetWindowRect($h, [ref]$rc)
  $bounds = @{ left=$rc.Left; top=$rc.Top; right=$rc.Right; bottom=$rc.Bottom }

  $procId = 0
  [void][Native.WinApi]::GetWindowThreadProcessId($h, [ref]$procId)
  $p = $null
  try { $p = Get-Process -Id $procId -ErrorAction Stop } catch {}

  return @{ hwnd=$h.ToInt64(); title=$title; process=if ($p) { $p.ProcessName } else { $null }; exe=if ($p) { $p.Path } else { $null }; bounds=$bounds }
}

function Capture-Frame([hashtable]$WindowInfo, [string]$PathJpg, [switch]$WindowOnly) {
  if (-not $WindowInfo) { return $false }
  $srcX = 0; $srcY = 0; $w = 0; $h = 0
  if ($WindowOnly -and $WindowInfo.bounds) {
    $b = $WindowInfo.bounds
    $srcX = [int]$b.left; $srcY = [int]$b.top
    $w = [int]([math]::Max(1, $b.right - $b.left))
    $h = [int]([math]::Max(1, $b.bottom - $b.top))
  } else {
    # fallback: capture primary screen
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen
    $srcX = $scr.Bounds.X; $srcY = $scr.Bounds.Y
    $w = $scr.Bounds.Width; $h = $scr.Bounds.Height
  }

  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen([System.Drawing.Point]::new($srcX,$srcY), [System.Drawing.Point]::new(0,0), [System.Drawing.Size]::new($w,$h))
    Save-Jpeg -Bitmap $bmp -Path $PathJpg -Quality 78
    return $true
  } finally { $g.Dispose(); $bmp.Dispose() }
}

function Capture-One {
  Ensure-Dir $ScreenshotDir
  $win = Get-ActiveWindowInfo
  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $framePath = Join-Path $ScreenshotDir ("frame_" + $timestamp + ".jpg")
  $frames = @()
  if (Capture-Frame -WindowInfo $win -PathJpg $framePath -WindowOnly:([bool]$CaptureWindowOnly)) {
    $frames += $framePath
    Write-Host "[VisionProbe] Captured 1 frame"
  } else {
    Write-Warning "[VisionProbe] Failed to capture screenshot"
  }
  return @{ frames = $frames; window = $win }
}

function Remove-LlamaNoise {
  param([string]$Text)
  if (-not $Text) { return $Text }
  $lines = $Text -split "`r?`n"
  $keep = New-Object System.Collections.Generic.List[string]
  foreach ($ln in $lines) {
    $x = $ln.Trim()
    if ($x -eq '') { continue }
    if ($x -match '^(ggml_|llama_|load_backend:|system info:|build info:|model type:|AVX|F16|Q[0-9]|BLAS\b|cuBLAS\b|CUDA\b|Vulkan\b|OpenCL\b|cpu_has_)') { continue }
    if ($x -match '^(sampler:|graph:|queue:|using.*backend|device\s+[0-9]+:)') { continue }
    $keep.Add($ln)
  }
  $clean = ($keep -join "`n").Trim()
  return $clean
}

function Clean-CaptionText {
  param([string]$Text)
  if (-not $Text) { return $Text }
  $t = ($Text -replace "\r\n?","`n").Trim()
  try { $t = [regex]::Replace($t, '^(?:The\s+(screenshot|image|screen)\s+shows\s+)', '', 'IgnoreCase') } catch {}
  return $t.Trim()
}

function Finalize-Caption {
  param([string]$Text, [int]$MaxSentences = 3, [int]$MaxChars = 700)
  $clean = Clean-CaptionText -Text $Text
  if (-not $clean) { return $clean }
  try {
    $parts = [regex]::Split($clean, '(?<=[\.!?])\s+') | Where-Object { $_ -and $_.Trim() -ne '' }
    if ($parts.Count -gt $MaxSentences) { $clean = ($parts | Select-Object -First $MaxSentences) -join ' ' }
  } catch {}
  if ($clean.Length -gt $MaxChars) { $clean = $clean.Substring(0, $MaxChars).Trim() }
  return $clean.Trim()
}

function Compose-FallbackCaption([hashtable]$Win) {
  $title = if ($Win.title) { $Win.title.Trim() } else { '' }
  $proc  = if ($Win.process) { $Win.process.Trim() } else { '' }
  $title = $title -replace ' - (Google Chrome|Microsoft Edge|Mozilla Firefox|YouTube|Visual Studio Code)$',''

  if ($proc -match 'chrome|msedge|firefox') { if ($title) { return "Browsing - $title" } else { return 'Browsing the web' } }
  if ($proc -match 'Code|devenv|idea64|pycharm|clion') { if ($title) { return "Coding - $title" } else { return 'Coding' } }
  if ($title) { return "Viewing: $title" }
  elseif ($proc) { return "Using $proc" }
  else { return 'Viewing the desktop' }
}

# ------------------ llama.cpp Invocation ------------------
function Invoke-Vision {
  param(
    [Parameter(Mandatory=$true)][string]$Prompt,
    [Parameter(Mandatory=$true)][string]$ImagePath
  )

  if (-not (Test-Path $Model))     { Write-Warning "[VisionProbe] Model not found: $Model"; return $null }
  if (-not (Test-Path $ImagePath)) { return $null }

  Ensure-Dir $LogsDir
  $pf = Join-Path $LogsDir ("vision-prompt-" + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + ".txt")
  try { [IO.File]::WriteAllText($pf, $Prompt, [Text.UTF8Encoding]::new($false)) } catch {}

  # Prefer local runner (keeps templating correct); forward -t and -ngl
  $runner = Join-Path $HomeDir 'tools\Start-LocalLLM.ps1'
  if (Test-Path $runner) {
    $params = @{ PromptFile=$pf; ModelPath=$Model; LlamaExe=$LlamaExe; CtxSize=$CtxSize; GpuLayers=$GpuLayers; MaxTokens=$NPredict; Temp=0.15; Images=@($ImagePath) }
    if ((Split-Path -Leaf $Model) -match 'llava' -and $Mmproj -and (Test-Path $Mmproj)) { $params.Mmproj = $Mmproj }
    try {
      # Pass threads to the runner via env since Threads is not a formal param there
      $oldThreads = $env:ECHO_LLAMA_THREADS
      if ($Threads -gt 0) { $env:ECHO_LLAMA_THREADS = "$Threads" }
      $raw = & $runner @params 2>&1 | Out-String
      $env:ECHO_LLAMA_THREADS = $oldThreads
      $txt = (Remove-LlamaNoise $raw).Trim(); if (-not $txt) { $txt = $raw.Trim() }
      try { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue } catch {}
      return $txt
    } catch {
      Write-Warning "[VisionProbe] Runner failed; falling back to direct CLI. $_"
      try { $env:ECHO_LLAMA_THREADS = $oldThreads } catch {}
    }
  }

  # Fallback: call llama executable directly
  if (-not (Test-Path $LlamaExe)) { Write-Warning "[VisionProbe] Llama exe not found: $LlamaExe"; try { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue } catch {}; return $null }
  $exe = $LlamaExe
  $useMtmd = ($exe.ToLower().EndsWith('llama-mtmd-cli.exe') -or ((Split-Path -Leaf $Model) -match 'llava'))

  $argsBase = @('-m', $Model)
  if ($useMtmd -and $Mmproj -and (Test-Path $Mmproj)) { $argsBase += @('--mmproj', $Mmproj) }
  $argsTail = @('--temp','0.15','-c',"$CtxSize",'-n',"$NPredict",'--image', $ImagePath, '--prompt-file', $pf, '--log-disable')
  if ($Threads -gt 0) { $argsTail += @('-t', "$Threads") }
  if ($GpuLayers -gt 0) { $argsTail += @('-ngl', "$GpuLayers") }

  try {
    $raw = & $exe @($argsBase + $argsTail) 2>&1 | Out-String
    $txt = (Remove-LlamaNoise $raw).Trim(); if (-not $txt) { $txt = $raw.Trim() }
    return $txt
  } catch {
    return $null
  } finally {
    try { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue } catch {}
  }
}

# ------------------ Caption Orchestration ------------------
function Describe-Image {
  param([string]$ImagePath, [hashtable]$Win)

  $wtitle = if ($Win.title) { $Win.title } else { '' }
  $wproc  = if ($Win.process) { $Win.process } else { '' }

  $ctx = 'Context: Application window.'
  if ($wproc -match 'chrome|msedge|firefox') { $ctx = 'Context: Web page — include site/page type and main heading.' }
  elseif ($wproc -match 'Code|devenv|idea|pycharm|clion') { $ctx = 'Context: VS Code/IDE — include file name, language, and panes.' }
  elseif ($wtitle -match 'YouTube') { $ctx = 'Context: YouTube watch page.' }

  $prompt = @"
$ctx
Be concrete and only describe what is visible.
Write $MaxSentences short sentences:
• Name the app/site and specific view.
• Mention key UI parts with rough positions (e.g., top-left sidebar, center panel).
• Quote 1–3 distinctive on-screen texts exactly (titles, filenames, menu items).
• If it looks like a game/HUD, include HUD elements and objective text visible.
No speculation.
"@

  $raw = Invoke-Vision -Prompt $prompt -ImagePath $ImagePath
  if (-not $raw) { return $null }
  $raw = (Remove-LlamaNoise $raw).Trim()
  $fin = Finalize-Caption -Text $raw -MaxSentences $MaxSentences -MaxChars $MaxChars
  if (-not $fin -or $fin.Trim().Length -eq 0) { $fin = Compose-FallbackCaption $Win }
  return $fin
}

function Harvest-Quotes { param([string]$Caption,[int]$Max=3)
  if (-not $Caption) { return @() }
  try {
    $q = [System.Text.RegularExpressions.Regex]::Matches($Caption, '"([^"]{4,80})"') | ForEach-Object { $_.Groups[1].Value.Trim() }
    $q = $q | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -Unique
    return @($q | Select-Object -First $Max)
  } catch { return @() }
}

function Cleanup-OldFrames { param([int]$KeepSeconds)
  if (-not (Test-Path -LiteralPath $ScreenshotDir)) { return }
  $cutoff = (Get-Date).AddSeconds(-$KeepSeconds)
  $files = @(Get-ChildItem -LiteralPath $ScreenshotDir -Filter 'frame_*.jpg' -File -ErrorAction SilentlyContinue)
  foreach ($f in $files) { if ($f.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } }
}

function Run-VisionBurst {
  # Stop/host flags
  if (Test-Path -LiteralPath $StopFile) { Write-Host "[VisionProbe] Stop flag found, exiting."; return $false }
  if ($StopFlagEnv -and (Test-Path -LiteralPath $StopFlagEnv)) { Write-Host "[VisionProbe] Global stop flag found, exiting."; return $false }
  if (-not $Force -and -not ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath))) { Write-Host "[VisionProbe] Host flag missing, exiting."; return $false }

  $cap = Capture-One
  if ($cap.frames.Count -eq 0) { Write-Warning "[VisionProbe] No screenshot captured"; return $true }
  $img = $cap.frames[0]

  $t0 = Get-Date
  $summary = Describe-Image -ImagePath $img -Win $cap.window
  $t1 = Get-Date

  if (-not $summary -or $summary.Trim().Length -eq 0) { $summary = Compose-FallbackCaption $cap.window }
  $summary = (Remove-LlamaNoise $summary).Trim()

  $visible = @()
  if (-not $SkipOCR) {
    # plug OCR here later if needed
  }
  if (-not $visible -or $visible.Count -eq 0) {
    $bt = $cap.window.title
    if ($bt) {
      try {
        $bt = $bt -replace ' - (Google Chrome|Microsoft Edge|Mozilla Firefox|Visual Studio Code|YouTube)$',''
        $bt = $bt -replace '^\((?:[0-9]+)\)\s*',''
        $bt = $bt.Trim()
      } catch {}
      if ($bt) { $visible = @($bt) }
    }
  }

  $doc = @{
    ts = IsoNow
    active_window = @{ title = $cap.window.title; process = $cap.window.process; exe = $cap.window.exe }
    burst = @{ frame_count = 1; duration_sec = 0; fps = 0; first_frame = (Split-Path -Leaf $img); last_frame = (Split-Path -Leaf $img) }
    summary = $summary
    salient = @(Harvest-Quotes -Caption $summary -Max 3)
    visible_text = @($visible)
  }

  $json = ($doc | ConvertTo-Json -Depth 8)
  AtomicWrite-Text -Path $CaptionPath -Content $json -Encoding ([Text.UTF8Encoding]::new($false))

  $delta = ($t1 - $t0).TotalSeconds
  $sumLen = if ($summary) { $summary.Length } else { 0 }
  Write-Host ("[VisionProbe] Caption written: {0} chars (delta={1:N3}s)" -f $sumLen, $delta)

  Cleanup-OldFrames -KeepSeconds $KeepFramesSec
  return $true
}

# ------------------ Main ------------------
Ensure-Dir $StateDir; Ensure-Dir $ScreenshotDir; Ensure-Dir $LogsDir; Enter-Singleton

Write-Host ("[VisionProbe] Model: {0}" -f $Model)
Write-Host ("[VisionProbe] Exe:   {0}" -f $LlamaExe)
if ((Split-Path -Leaf $Model) -match 'llava') {
  if ($Mmproj -and (Test-Path $Mmproj)) { Write-Host ("[VisionProbe] Mmproj: {0}" -f $Mmproj) } else { Write-Warning "[VisionProbe] LLaVA model but no mmproj found - captions may be empty." }
}
Write-Host ("[VisionProbe] Ctx={0}, NPred={1}, Threads={2}, GpuLayers={3}, Fast=False, SkipOCR={4}, Sentences={5}" -f $CtxSize,$NPredict,$Threads,$GpuLayers,$SkipOCR,$MaxSentences)

Write-Host ("[VisionProbe] Starting single-shot mode: 1 screenshot every {0}s" -f $BurstIntervalSec)
Write-Host ("[VisionProbe] Keeping last {0}s of frames" -f $KeepFramesSec)
Write-Host ("[VisionProbe] Output: {0}" -f $CaptionPath)

if ($Once) { [void](Run-VisionBurst); return }

# Clock-driven cadence so processing time doesn't stretch the interval
$next = Get-Date
while ($true) {
  try {
    $cont = Run-VisionBurst
    if (-not $cont) { break }
  } catch { Write-Warning ("[VisionProbe] Error: {0}" -f $_.Exception.Message) }

  $next = $next.AddSeconds([Math]::Max(1, $BurstIntervalSec))
  $sleep = [int][Math]::Max(0, ($next - (Get-Date)).TotalSeconds)
  if ($sleep -gt 0) { Start-Sleep -Seconds $sleep }
}
