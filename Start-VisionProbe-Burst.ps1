<#
  Start-VisionProbe.ps1 — fresh rewrite

  PURPOSE
  - Describe WHAT'S ON SCREEN (inside the active window) in clear sentences.
  - Favor accuracy and structure; accept a little latency if it improves quality.
  - OCR is optional and treated as a hint only.

  HIGHLIGHTS
  - Backends: llama.cpp CLI (default), llama.cpp server (OpenAI-compatible), or Ollama.
  - Sentence-only prompt (no bullets) + robust cleaner that preserves content.
  - Optional second-pass fallback for richer detail.
  - Emits JSON: { ts, active_window{title,process,exe}, burst{...}, summary, visible_text[], salient[] }

  QUICK ENV KNOBS
  - ECHO_VISION_BACKEND   = auto | llama_cli | llama_server | ollama   (default: auto -> llama_cli)
  - ECHO_VISION_MODEL     = model name or path (ollama: model tag; server: model id; cli: .gguf path)
  - ECHO_VISION_MMPROJ    = path to mmproj (needed for LLaVA via CLI/mtmd)
  - ECHO_VISION_SERVER    = http://127.0.0.1:8080 (llama-server) or http://127.0.0.1:11434 (ollama)
  - ECHO_VISION_SKIP_OCR  = 0/1 (default 1: skip OCR, we still extract quotes from caption)
  - ECHO_VISION_FAST      = 0/1 (shorter prompt)
  - ECHO_VISION_SENTENCES = 4 (default) — number of sentences to request
  - ECHO_VISION_RETRY     = 1/0 — second pass if first caption is short
  - ECHO_VISION_CTX       = 1536 (cli/server/ollama)
  - ECHO_VISION_NPREDICT  = 280  (room for 4 detailed sentences)
  - ECHO_VISION_THREADS   = <cores>
  - ECHO_VISION_GPU_LAYERS= 999
  - ECHO_VISION_INTERVAL_SEC = 5

  OUTPUT
  - Writes D:\Echo\state\screen.caption.json (or STATE_DIR)
#>

param(
  [switch]$Once,
  [int]$BurstIntervalSec = 5,
  [int]$KeepFramesSec = 60,
  [switch]$Force
)

# ------------------ Config / Defaults ------------------
$HomeDir       = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME } else { 'D:\Echo' }
$StateDir      = if ($env:STATE_DIR -and $env:STATE_DIR.Trim()) { $env:STATE_DIR } else { Join-Path $HomeDir 'state' }
$ScreenshotDir = Join-Path $HomeDir 'sense\screenshots'
$CaptionPath   = Join-Path $StateDir 'screen.caption.json'
$PidFile       = Join-Path $StateDir 'visionprobe.pid'
$StopFile      = Join-Path $StateDir 'visionprobe.stop'

$HostFlagPath  = $env:ECHO_HOST_FLAG
$StopFlagEnv   = $env:ECHO_STOP_FLAG

# Vision tuning
$CtxSize   = try { [int]($env:ECHO_VISION_CTX) } catch { 1536 }
if ($CtxSize -le 0) { $CtxSize = 1536 }
$NPredict  = try { [int]($env:ECHO_VISION_NPREDICT) } catch { 280 }
if ($NPredict -le 64) { $NPredict = 160 }
$Threads   = try { [int]($env:ECHO_VISION_THREADS) } catch { 0 }
$GpuLayers = try { [int]($env:ECHO_VISION_GPU_LAYERS) } catch { 999 }
if ($GpuLayers -le 0) { $GpuLayers = 999 }
$Sentences = try { [int]($env:ECHO_VISION_SENTENCES) } catch { 4 }
if ($Sentences -lt 2 -or $Sentences -gt 8) { $Sentences = 4 }
$FastMode  = ($env:ECHO_VISION_FAST -match '^(1|true|yes)$')
$RetryPass = ($env:ECHO_VISION_RETRY -match '^(1|true|yes)$')
$SkipOCR   = if ($env:ECHO_VISION_SKIP_OCR) { ($env:ECHO_VISION_SKIP_OCR -match '^(1|true|yes)$') } else { $true }

# Backend selection
$Backend  = if ($env:ECHO_VISION_BACKEND) { $env:ECHO_VISION_BACKEND.ToLower() } else { 'auto' }
$Server   = if ($env:ECHO_VISION_SERVER) { $env:ECHO_VISION_SERVER.TrimEnd('/') } else { '' }
$Model    = if ($env:ECHO_VISION_MODEL) { $env:ECHO_VISION_MODEL } else { '' }
$Mmproj   = if ($env:ECHO_VISION_MMPROJ) { $env:ECHO_VISION_MMPROJ } else { '' }

# CLI defaults (fallback)
$LlamaExe = if ($env:LLAMA_VISION_EXE -and (Test-Path $env:LLAMA_VISION_EXE)) { $env:LLAMA_VISION_EXE }
           elseif (Test-Path 'D:\\llama-cpp\\llama-mtmd-cli.exe') { 'D:\\llama-cpp\\llama-mtmd-cli.exe' }
           elseif ($env:LLAMA_EXE -and (Test-Path $env:LLAMA_EXE)) { $env:LLAMA_EXE }
           else { 'D:\\llama-cpp\\llama-cli.exe' }

# Try to discover a default model path if missing for CLI
if (-not $Model -and -not ($Backend -in @('ollama','llama_server'))) {
  foreach ($d in @((Join-Path $HomeDir 'models'), (Join-Path $HomeDir 'model'))) {
    if (Test-Path $d) {
      $m = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '\.(gguf)$' -and ($_.Name -match 'llava|qwen.*vl') } |
           Sort-Object Length -Descending |
           Select-Object -First 1
      if ($m) { $Model = $m.FullName; break }
    }
  }
}

# Sanitize an environment-provided mmproj path: drop if invalid or nonexistent
try {
  if ($Mmproj) {
    $invalid = [System.IO.Path]::GetInvalidPathChars()
    if ($Mmproj.IndexOfAny($invalid) -ne -1) {
      $Mmproj = ''
    } elseif (-not (Test-Path -LiteralPath $Mmproj)) {
      $Mmproj = ''
    }
  }
} catch { $Mmproj = '' }

# Try to auto-discover an mmproj if not provided (for llama.cpp vision models)
if (-not $Mmproj -and $Model -and ($Model.ToLower().EndsWith('.gguf'))) {
  try {
    $modelDir  = Split-Path -Path $Model -Parent
    $modelLeaf = Split-Path -Path $Model -Leaf
    $modelBase = [System.IO.Path]::GetFileNameWithoutExtension($modelLeaf)
    # Heuristic: strip common quant suffix like -Q* or -fNN from the end for matching
    $modelStem = try { ($modelBase -replace '-(Q\d.*|f\d+)$','') } catch { $modelBase }
    $searchDirs = @($modelDir)
    if (-not ($searchDirs -contains (Join-Path $HomeDir 'models'))) { $searchDirs += (Join-Path $HomeDir 'models') }
    $candidates = @()
    foreach ($dir in $searchDirs) {
      if (Test-Path -LiteralPath $dir) {
        $candidates += @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -ieq '.gguf' -and $_.Name -match 'mmproj' })
      }
    }
    if ($candidates.Count -gt 0) {
      # Prefer a projector that shares the stem with the model name
      $preferred = @($candidates | Where-Object { $_.Name -like ("$modelStem*mmproj*") })
      $pick = if ($preferred.Count -gt 0) { $preferred | Select-Object -First 1 } else { $candidates | Select-Object -First 1 }
      if ($pick -and (Test-Path -LiteralPath $pick.FullName)) { $Mmproj = $pick.FullName }
    }
  } catch { }
}

# Capture: focus on active window by default
$CaptureWindowOnly = $true
try { if ($env:ECHO_VISION_WINDOW_ONLY -and ($env:ECHO_VISION_WINDOW_ONLY -match '^(0|false|no)$')) { $CaptureWindowOnly = $false } } catch {}

# JPEG quality & ctx tradeoff
$JpegQuality = if ($FastMode) { 70 } else { 80 }

# -------------- Helpers --------------
function Ensure-Dir([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function IsoNow { (Get-Date).ToString('o') }

function AtomicWrite-Text([string]$Path,[string]$Content,[System.Text.Encoding]$Encoding) {
  $tmp = $Path + '.tmp'
  [System.IO.File]::WriteAllText($tmp, $Content, $Encoding)
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

try { Add-Type -AssemblyName System.Drawing | Out-Null } catch {}

function Save-Jpeg([System.Drawing.Bitmap]$Bitmap, [string]$Path, [int]$Quality=$JpegQuality) {
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  if (-not $codec) { $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg); return }
  $encParms = New-Object System.Drawing.Imaging.EncoderParameters 1
  $encParms.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
  $Bitmap.Save($Path, $codec, $encParms)
}

# Win32 helpers for active window & monitor bounds
try {
  Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
namespace Native {
  public static class WinApi {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO mi);
    public const int MONITOR_DEFAULTTONEAREST = 2;
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  }
}
"@
} catch {}

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
  $procId = 0; [void][Native.WinApi]::GetWindowThreadProcessId($h, [ref]$procId)
  $p = $null; try { $p = Get-Process -Id $procId -ErrorAction Stop } catch {}
  return @{ hwnd=$h.ToInt64(); title=$title; process=if ($p) { $p.ProcessName } else { $null }; exe=if ($p) { $p.Path } else { $null }; bounds=$bounds; mon=$mon }
}

function Capture-Frame([hashtable]$WindowInfo, [string]$PathJpg, [switch]$WindowOnly) {
  if (-not $WindowInfo) { return $false }
  $srcX = 0; $srcY = 0; $w = 0; $h = 0
  if ($WindowOnly -and $WindowInfo.bounds) {
    $b = $WindowInfo.bounds; $srcX = [int]$b.left; $srcY = [int]$b.top
    $w = [int]([math]::Max(1, $b.right - $b.left)); $h = [int]([math]::Max(1, $b.bottom - $b.top))
  } elseif ($WindowInfo.mon) {
    $m = $WindowInfo.mon; $srcX = [int]$m.left; $srcY = [int]$m.top
    $w = [int]([math]::Max(1, $m.right - $m.left)); $h = [int]([math]::Max(1, $m.bottom - $m.top))
  } else { return $false }
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen([System.Drawing.Point]::new($srcX,$srcY), [System.Drawing.Point]::new(0,0), [System.Drawing.Size]::new($w,$h)); Save-Jpeg -Bitmap $bmp -Path $PathJpg -Quality $JpegQuality; return $true } finally { $g.Dispose(); $bmp.Dispose() }
}

function Capture-One {
  Ensure-Dir $ScreenshotDir
  $win = Get-ActiveWindowInfo
  $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $framePath = Join-Path $ScreenshotDir "frame_$timestamp.jpg"
  $frames = @()
  if (Capture-Frame -WindowInfo $win -PathJpg $framePath -WindowOnly:([bool]$CaptureWindowOnly)) { $frames += $framePath; Write-Host "[VisionProbe] Captured 1 frame" } else { Write-Warning "[VisionProbe] Failed to capture screenshot" }
  return @{ frames = $frames; window = $win }
}

# ---------- Caption cleaning & extraction ----------
function Clean-CaptionText {
  param([string]$Text, [string]$Prompt)
  if (-not $Text) { return $Text }
  $t = ($Text -replace "\r\n?","`n").Trim()
  $p = if ($Prompt) { ($Prompt -replace "\r\n?","`n").Trim() } else { '' }
  $lines = @($t -split "`n")
  $promptSet = @{}; if ($p) { foreach ($pl in ($p -split "`n")) { $promptSet[$pl.Trim()] = $true } }
  $out = New-Object System.Collections.Generic.List[string]
  $skipping = $true
  foreach ($ln in $lines) {
    $x = $ln.Trim()
    $isInstr = ($x -match '^(You are|Return ONLY|No bullet|Cover:|Do not|Context:|Schema:|Hints:|Format:|Instructions:)')
    $isPromptLine = ($p -and $promptSet.ContainsKey($x))
    if ($skipping -and ($isInstr -or $isPromptLine -or $x -eq '')) { continue }
    $skipping = $false
    $out.Add($ln)
  }
  $joined = ($out -join ' ').Trim()
  try { $joined = [regex]::Replace($joined, '^(?:The\s+(screenshot|image|screen)\s+shows\s+)', '', 'IgnoreCase') } catch {}
  try { $joined = $joined -replace '[\u201C\u201D\u201E\u201F]', '"' -replace '[\u2018\u2019]', "'" -replace '[\u2013\u2014\u2212]', '-' } catch {}
  return $joined.Trim()
}

function Finalize-Caption {
  param([string]$Text, [string]$Prompt)
  $clean = Clean-CaptionText -Text $Text -Prompt $Prompt
  if (-not $clean) { return $clean }
  # Clamp to N sentences, ~700 chars
  $maxSent = [Math]::Max(2, [Math]::Min(8, $Sentences))
  $parts = @()
  try { $parts = [regex]::Split($clean, '(?<=[\.!?])\s+') | Where-Object { $_.Trim() } } catch {}
  if ($parts.Count -gt $maxSent) { $clean = ($parts | Select-Object -First $maxSent) -join ' ' }
  if ($clean.Length -gt 700) { $clean = $clean.Substring(0,700).Trim() }
  return $clean
}

function Harvest-Quotes([string]$Caption,[int]$Max=4) {
  if (-not $Caption) { return @() }
  try { return ([regex]::Matches($Caption, '"([^"]{4,80})"') | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -First $Max) } catch { return @() }
}

function Compose-FallbackCaption([hashtable]$Win) {
  $title = if ($Win.title) { $Win.title.Trim() } else { '' }
  $proc  = if ($Win.process) { $Win.process.Trim() } else { '' }
  $title = $title -replace ' - (Google Chrome|Microsoft Edge|Mozilla Firefox|YouTube|Visual Studio Code)$',''
  if ($proc -match 'chrome|msedge|firefox') { return (if ($title) { "Browsing — $title" } else { 'Browsing the web' }) }
  if ($proc -match 'Code|devenv|idea64|pycharm|clion') { return (if ($title) { "Coding — $title" } else { 'Coding' }) }
  if ($title) { return "Viewing: $title" } elseif ($proc) { return "Using $proc" } else { return 'Viewing the desktop' }
}

# ---------- Backend callers ----------
function To-Base64([string]$Path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }

function Invoke-LlamaServerV1Chat([string]$Server,[string]$Model,[string]$Prompt,[string]$ImagePath) {
  $b64 = To-Base64 $ImagePath
  $body = @{ model=$Model; temperature=0.15; max_tokens=$NPredict; messages=@(@{role='user'; content=@(@{type='input_text'; text=$Prompt}, @{type='input_image'; image_url=('data:image/jpeg;base64,'+$b64)})}) } | ConvertTo-Json -Depth 8
  try { return (Invoke-RestMethod -Method Post -Uri ($Server+'/v1/chat/completions') -ContentType 'application/json' -Body $body -TimeoutSec 120).choices[0].message.content } catch { return $null }
}

function Invoke-OllamaGenerate([string]$Server,[string]$Model,[string]$Prompt,[string]$ImagePath) {
  $b64 = To-Base64 $ImagePath
  $opts = @{ num_ctx=$CtxSize; num_predict=$NPredict; temperature=0.15 }
  $body = @{ model=$Model; prompt=$Prompt; stream=$false; images=@($b64); options=$opts } | ConvertTo-Json -Depth 8
  try { return (Invoke-RestMethod -Method Post -Uri ($Server+'/api/generate') -ContentType 'application/json' -Body $body -TimeoutSec 120).response } catch { return $null }
}

function Invoke-LlamaCli([string]$Prompt,[string]$ImagePath) {
  # Use a local helper if present (preferred because it handles mmproj and flags)
  $runner = Join-Path $HomeDir 'tools\Start-LocalLLM.ps1'
  if (Test-Path $runner) {
    $logsDir = Join-Path $HomeDir 'logs'; Ensure-Dir $logsDir
    $pf = Join-Path $logsDir ("vision-prompt-" + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + ".txt")
    [IO.File]::WriteAllText($pf, $Prompt, [Text.UTF8Encoding]::new($false))
    $params = @{ PromptFile=$pf; ModelPath=$Model; LlamaExe=$LlamaExe; CtxSize=$CtxSize; GpuLayers=$GpuLayers; MaxTokens=$NPredict; Temp=0.15; Images=@($ImagePath) }
    try {
      if ($Mmproj) {
        $invalid = [System.IO.Path]::GetInvalidPathChars()
        if ($Mmproj.IndexOfAny($invalid) -eq -1 -and (Test-Path -LiteralPath $Mmproj)) { $params.Mmproj = $Mmproj }
      }
    } catch {}
    try { $out = & $runner @params 2>$null | Out-String; return $out.Trim() } catch { return $null } finally { try { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue } catch {} }
  }
  # Fallback: attempt direct CLI (best-effort)
  $args = @()
  if ($LlamaExe.ToLower().EndsWith('llama-mtmd-cli.exe')) {
    $mmOk = $false
    try {
      if ($Mmproj) {
        $invalid = [System.IO.Path]::GetInvalidPathChars()
        if ($Mmproj.IndexOfAny($invalid) -eq -1 -and (Test-Path -LiteralPath $Mmproj)) { $mmOk = $true }
      }
    } catch { $mmOk = $false }
    if ($mmOk) { $args += @('-m', $Model, '--mmproj', $Mmproj) } else { $args += @('-m', $Model) }
  } else { $args += @('-m', $Model) }
  $args += @('--temp','0.15','-c',"$CtxSize",'-n',"$NPredict",'--image', $ImagePath, '--prompt', $Prompt)
  try { return (& $LlamaExe @args | Out-String).Trim() } catch { return $null }
}

function Invoke-Vision([string]$Prompt,[string]$ImagePath) {
  $chosen = $Backend
  if ($chosen -eq 'auto') { $chosen = if ($Server -match '11434' -or $Server.ToLower().Contains('ollama')) { 'ollama' } elseif ($Server) { 'llama_server' } else { 'llama_cli' } }
  if ($chosen -eq 'ollama') { $m = if ($Model) { $Model } else { 'llava:latest' }; $res = Invoke-OllamaGenerate -Server $Server -Model $m -Prompt $Prompt -ImagePath $ImagePath; if ($res) { return $res } }
  if ($chosen -eq 'llama_server') { $m = if ($Model) { $Model } else { 'vision' }; $res = Invoke-LlamaServerV1Chat -Server $Server -Model $m -Prompt $Prompt -ImagePath $ImagePath; if ($res) { return $res } }
  return (Invoke-LlamaCli -Prompt $Prompt -ImagePath $ImagePath)
}

# ---------- OCR (optional; hint only) ----------
function Invoke-OCRTexts([string]$ImagePath,[int]$MaxItems=6) {
  $prompt = @"
  Return ONLY a JSON array of up to $MaxItems distinctive on-screen texts (long headings, titles, file names). Ignore generic words like Title, Button, Tab, Home, Settings, Search. No extra text.
"@
  $raw = Invoke-Vision -Prompt $prompt -ImagePath $ImagePath
  if (-not $raw) { return @() }
  # try parse array
  try { $arr = ($raw | ConvertFrom-Json -AsArray) } catch { $arr = $null }
  if ($arr -and $arr.Count -gt 0) { return @($arr | ForEach-Object { if ($_ -is [string]) { $_.Trim() } } | Where-Object { $_ }) }
  # fallback: extract quoted strings
  return (Harvest-Quotes -Caption $raw -Max $MaxItems)
}

function Filter-OCRTexts {
  param(
    [string[]]$Texts
  )

  $stop = @('title','button','tab','tab name','home','video','audio','search','settings','file','edit','view','help',
            'google','chrome','youtube','new tab','untitled','welcome','ok','cancel','close')

  $uniq = @($Texts | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)

  return @(
    $uniq | ForEach-Object { $_.Trim() } | Where-Object {
      $lo = $_.ToLower()
      ($_ -match '[A-Za-z0-9]') -and $_.Length -ge 4 -and -not ($stop -contains $lo) -and
      (($_ -match '\s') -or ($_ -match '\d') -or $_.Length -ge 8)
    }
  )
}


# ---------- Main run ----------
function Describe-Image([string]$ImagePath,[hashtable]$Win) {
  $n = $Sentences
  if ($FastMode) { $n = [Math]::Max(2, [Math]::Min(3, $Sentences)) }
  $prompt = @"
  Return ONLY $n concise sentences describing what is visible INSIDE the active window.
  No bullet points, no lists, no headings, no prefaces.
  Cover: the app/site and view; the main on-screen regions with positions (top-left/center/right/bottom); 1–3 exact quoted texts; obvious controls/actions visible.
  Do not mention the OS chrome or window title. Do not speculate.
"@
  $raw = Invoke-Vision -Prompt $prompt -ImagePath $ImagePath
  $cap = Finalize-Caption -Text $raw -Prompt $prompt
  if (-not $cap -or $cap.Length -lt 120) {
    if ($RetryPass) {
      $retry = @"
      Rewrite with more concrete UI details and positions. Keep to $n sentences and quote 2 visible strings. No lists.
"@
      $raw2 = Invoke-Vision -Prompt $retry -ImagePath $ImagePath
      $cap2 = Finalize-Caption -Text $raw2 -Prompt $retry
      if ($cap2 -and ($cap2.Length -gt ($cap?.Length))) { $cap = $cap2 }
    }
  }
  if (-not $cap -or $cap.Trim().Length -lt 40) { $cap = Compose-FallbackCaption $Win }
  return $cap
}

function Cleanup-OldFrames([int]$KeepSeconds) {
  if (-not (Test-Path -LiteralPath $ScreenshotDir)) { return }
  $cutoff = (Get-Date).AddSeconds(-$KeepSeconds)
  $files = @(Get-ChildItem -LiteralPath $ScreenshotDir -Filter 'frame_*.jpg' -File -ErrorAction SilentlyContinue)
  foreach ($f in $files) { if ($f.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } }
}

function Enter-Singleton {
  if (Test-Path -LiteralPath $PidFile) {
    try { $old = Get-Content -LiteralPath $PidFile -ErrorAction Stop; if ($old -match '^\d+$' -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) { Write-Host "[VisionProbe] Already running (PID=$old). Exiting."; exit 0 } } catch {}
  }
  $PID | Out-File -LiteralPath $PidFile -Encoding ascii -Force
  Register-EngineEvent PowerShell.Exiting -Action { try { Remove-Item -LiteralPath $using:PidFile -Force -ErrorAction SilentlyContinue } catch {} } | Out-Null
}

function Run-VisionBurst {
  Ensure-Dir $StateDir; Ensure-Dir $ScreenshotDir
  $hostOk = $Force -or ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath))
  if (-not $hostOk) { Write-Host "[VisionProbe] Host flag missing; skipping capture."; return }

  $cap = Capture-One
  if ($cap.frames.Count -eq 0) { Write-Warning "[VisionProbe] No screenshot captured"; return }
  $img = $cap.frames[0]

  # Caption first (reliable, sentence-only)
  $summary = Describe-Image -ImagePath $img -Win $cap.window

  # visible_text via OCR (optional). If skipped, harvest from caption quotes.
  $visible = @()
  if (-not $SkipOCR) {
    $ocr = Invoke-OCRTexts -ImagePath $img -MaxItems 6
    $visible = @(Filter-OCRTexts -Texts $ocr)
  }
  if (-not $visible -or $visible.Count -eq 0) { $visible = @(Harvest-Quotes -Caption $summary -Max 4) }
  if (-not $visible -or $visible.Count -eq 0) {
    $bt = $cap.window.title; if ($bt) { $bt = $bt -replace ' - (Google Chrome|Microsoft Edge|Mozilla Firefox|Visual Studio Code|YouTube)$',''; $bt = $bt -replace '^\((?:\d+)\)\s*',''; if ($bt.Trim()) { $visible = @($bt.Trim()) } }
  }

  # Build JSON doc
  $doc = @{
    ts = IsoNow
    active_window = @{ title = $cap.window.title; process = $cap.window.process; exe = $cap.window.exe }
    burst = @{ frame_count = 1; duration_sec = 0; fps = 0; first_frame = (Split-Path -Leaf $img); last_frame = (Split-Path -Leaf $img) }
    summary = $summary
    salient = @(Harvest-Quotes -Caption $summary -Max 3)
    visible_text = @($visible)
  }

  $json = $doc | ConvertTo-Json -Depth 8
  AtomicWrite-Text -Path $CaptionPath -Content $json -Encoding ([Text.UTF8Encoding]::new($false))
  $len = if ($summary) { $summary.Length } else { 0 }
  Write-Host ("[VisionProbe] Caption written: {0} chars" -f $len)
  Cleanup-OldFrames -KeepSeconds $KeepFramesSec
}

# ------------------ Main ------------------
Ensure-Dir $StateDir
Ensure-Dir $ScreenshotDir
Enter-Singleton

# Interval override
try { if ($env:ECHO_VISION_INTERVAL_SEC -and $env:ECHO_VISION_INTERVAL_SEC.Trim()) { $BurstIntervalSec = [int]$env:ECHO_VISION_INTERVAL_SEC } } catch {}

Write-Host "[VisionProbe] Backend: $Backend | Server: $Server | Model: $Model"
if ($Mmproj) { Write-Host "[VisionProbe] Mmproj: $Mmproj" }
Write-Host "[VisionProbe] Ctx=$CtxSize, NPred=$NPredict, Threads=$Threads, GpuLayers=$GpuLayers, Fast=$FastMode, SkipOCR=$SkipOCR, Sentences=$Sentences"
Write-Host "[VisionProbe] Starting single-shot mode: 1 screenshot every ${BurstIntervalSec}s"
Write-Host "[VisionProbe] Keeping last ${KeepFramesSec}s of frames"

if ($Once) { Run-VisionBurst; return }

while ($true) {
  try {
    if (Test-Path -LiteralPath $StopFile) { Write-Host "[VisionProbe] Stop flag found, exiting."; break }
    if ($StopFlagEnv -and (Test-Path -LiteralPath $StopFlagEnv)) { Write-Host "[VisionProbe] Global stop flag found, exiting."; break }
    if (-not $Force -and -not ($HostFlagPath -and (Test-Path -LiteralPath $HostFlagPath))) { Write-Host "[VisionProbe] Host flag missing, exiting."; break }
    Run-VisionBurst
  } catch {
    Write-Warning "[VisionProbe] Error: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds ([Math]::Max(1, $BurstIntervalSec))
}
