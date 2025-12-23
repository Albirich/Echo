[CmdletBinding()]
param(
  [switch]$Once,
  [int]$IntervalSec = 1,
  [int]$KeepFramesSec = 90,
  [string]$OutJsonl
)

$ErrorActionPreference = 'Continue'  # Changed from 'Stop' to allow llama stderr warnings
$ProgressPreference    = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

try { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $ScriptRoot = Get-Location }
$coreModule = Join-Path $ScriptRoot 'tools\Echo.Core.psm1'
if (Test-Path -LiteralPath $coreModule) { Import-Module $coreModule -Force -DisableNameChecking }

function Log([string]$msg)  { [Console]::WriteLine("[VisionLite] $msg") }
function Warn([string]$msg) { [Console]::WriteLine("[VisionLite][WARN] $msg") }

$paths = Get-EchoPaths -Home $ScriptRoot
Ensure-EchoPaths $paths
$env:ECHO_HOME = $paths.Home

$frameDir = Join-Path $paths.Home 'sense\screenshots'
if (-not (Test-Path -LiteralPath $frameDir)) { New-Item -ItemType Directory -Force -Path $frameDir | Out-Null }

if (-not $OutJsonl -or -not $OutJsonl.Trim()) {
  $OutJsonl = Join-Path $paths.UI 'screen.captions.jsonl'
}
$rawLog = Join-Path $paths.Logs 'vision.raw.log'
$historyPath = Join-Path $paths.State 'screen.captions.history.json'
$promptDir = Join-Path $paths.Home 'config\vision-prompts'
if (-not (Test-Path -LiteralPath $promptDir)) { New-Item -ItemType Directory -Force -Path $promptDir | Out-Null }
$roomStatePath = Join-Path $paths.UI 'state.json'
$rowStatePath = Join-Path $paths.State 'vision.row.txt'
$rowCycle = @('1','2','3','4','5')
function Get-ClueRow {
  if (-not (Test-Path -LiteralPath $rowStatePath)) { return $rowCycle[0] }
  try {
    $v = (Get-Content -LiteralPath $rowStatePath -Raw -Encoding UTF8).Trim()
    if ($rowCycle -contains $v) { return $v }
  } catch {}
  return $rowCycle[0]
}
function Advance-ClueRow([string]$current) {
  $idx = $rowCycle.IndexOf($current)
  $next = if ($idx -ge 0 -and $idx -lt $rowCycle.Count - 1) { $rowCycle[$idx+1] } else { $rowCycle[0] }
  try { Set-Content -LiteralPath $rowStatePath -Value $next -Encoding UTF8 -Force } catch {}
}

function Resolve-VisionModel {
  $qwenDefault = Join-Path $paths.Models 'Qwen2.5-VL-3B-Abliterated-Caption-it.Q8_0.gguf'
  $llavaPattern = 'llava-phi-3-mini'
  $fallback7b = Join-Path $paths.Models 'thesby_Qwen2.5-VL-7B-NSFW-Caption-V3-Q3_K_XL.gguf'
  if ($env:ECHO_VISION_MODEL -and (Test-Path -LiteralPath $env:ECHO_VISION_MODEL)) {
    if ($env:ECHO_VISION_MODEL -notmatch $llavaPattern) { return $env:ECHO_VISION_MODEL }
    Warn "ECHO_VISION_MODEL points to llava mini; overriding to Qwen2.5 vision default."
    $env:ECHO_VISION_MODEL = $fallback7b
    return $env:ECHO_VISION_MODEL
  }
  if ($env:ECHO_VISION_LLAMACPP_MODEL -and (Test-Path -LiteralPath $env:ECHO_VISION_LLAMACPP_MODEL)) {
    if ($env:ECHO_VISION_LLAMACPP_MODEL -notmatch $llavaPattern) { return $env:ECHO_VISION_LLAMACPP_MODEL }
    Warn "ECHO_VISION_LLAMACPP_MODEL points to llava mini; overriding to Qwen2.5 vision default."
    $env:ECHO_VISION_LLAMACPP_MODEL = $fallback7b
    return $env:ECHO_VISION_LLAMACPP_MODEL
  }
  if (Test-Path -LiteralPath $fallback7b) { return $fallback7b }
  return $qwenDefault
}

function Resolve-VisionMmproj {
  param([string]$ModelPath)
  if ($env:ECHO_VISION_MMPROJ -and (Test-Path -LiteralPath $env:ECHO_VISION_MMPROJ)) { return $env:ECHO_VISION_MMPROJ }
  if ($ModelPath -and (Test-Path -LiteralPath $ModelPath)) {
    $dir = Split-Path -Parent $ModelPath
    $base = [IO.Path]::GetFileNameWithoutExtension($ModelPath) -replace '\.gguf$',''
    $is7b = ($base -match '(?i)7b')
    $is3b = ($base -match '(?i)3b')
    $candidates = Get-ChildItem -LiteralPath $dir -Filter '*mmproj*.gguf' -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch 'llava-phi-3-mini' }
    if ($candidates) {
      # prefer matching prefix, otherwise match on model size (7B vs 3B)
      $pref = $candidates | Where-Object { $_.BaseName -like "$base*" }
      if (-not $pref -or $pref.Count -eq 0) {
        $pref = $candidates | Where-Object {
          ($is7b -and $_.Name -match '(?i)7b') -or ($is3b -and $_.Name -match '(?i)3b')
        }
        if (-not $pref -or $pref.Count -eq 0) { $pref = $candidates }
      }
      # prefer Q8_0 then Q4/Q6 then anything
      $ordered = $pref | Sort-Object { 
        if ($_.Name -match 'Q8_0') { 0 }
        elseif ($_.Name -match 'Q6') { 1 }
        elseif ($_.Name -match 'Q4') { 2 }
        else { 3 }
      }, Name
      return $ordered[0].FullName
    }
  }
  # Explicitly avoid the llava mmproj; fall back to Qwen2.5 mmproj
  return Join-Path $paths.Models 'Qwen2.5-VL-3B-Abliterated-Caption-it.mmproj-Q8_0.gguf'
}

$llamaExe = if ($env:LLAMA_VISION_EXE -and (Test-Path $env:LLAMA_VISION_EXE)) { $env:LLAMA_VISION_EXE } else { 'D:\llama-cpp\llama-mtmd-cli.exe' }
$model    = Resolve-VisionModel
$mmproj   = Resolve-VisionMmproj -ModelPath $model
$clueModel = $null
$clueMmproj = $null
if ($env:ECHO_VISION_CLUES_MODEL -and (Test-Path -LiteralPath $env:ECHO_VISION_CLUES_MODEL)) {
  $clueModel = $env:ECHO_VISION_CLUES_MODEL
  if ($env:ECHO_VISION_CLUES_MMPROJ -and (Test-Path -LiteralPath $env:ECHO_VISION_CLUES_MMPROJ)) {
    $clueMmproj = $env:ECHO_VISION_CLUES_MMPROJ
  } else {
    $clueMmproj = Resolve-VisionMmproj -ModelPath $clueModel
  }
}

if (-not (Test-Path -LiteralPath $llamaExe)) { throw "llama-mtmd-cli.exe not found (set LLAMA_VISION_EXE)" }

$threads   = if ($env:ECHO_VISION_THREADS) { [int]$env:ECHO_VISION_THREADS } else { 4 }
$threads   = [Math]::Max(1, $threads)
$gpuLayers = if ($env:ECHO_VISION_GPU_LAYERS) { [int]$env:ECHO_VISION_GPU_LAYERS } else { 999 }
$ctxSize   = if ($env:ECHO_VISION_CTX) { [int]$env:ECHO_VISION_CTX } else { 4096 }
# Force higher context for structured extraction to reduce contamination
if ($ctxSize -lt 3072) { $ctxSize = 4096 }

$npredict  = if ($env:ECHO_VISION_NPREDICT) { [int]$env:ECHO_VISION_NPREDICT } else { 300 }
# Need enough tokens for 4 cells with clues
if ($npredict -lt 250) { $npredict = 300 }
$displayIdx = 2
try {
  if ($env:ECHO_VISION_DISPLAY -and $env:ECHO_VISION_DISPLAY.Trim()) {
    $displayIdx = [int]$env:ECHO_VISION_DISPLAY
    if ($displayIdx -gt 0) { $displayIdx-- } # convert to zero-based
  }
} catch {}
Log ("Vision exe: $llamaExe")
Log ("Vision model: $model")
Log ("Vision mmproj: $mmproj")
Log ("Display index (zero-based): $displayIdx")
Log ("Threads=$threads, GPU layers=$gpuLayers, Ctx=$ctxSize, NPredict=$npredict")

function Capture-Screen {
  param([int]$DisplayIndex,[string]$OutPath)
  $screens = [System.Windows.Forms.Screen]::AllScreens
  if (-not $screens -or $screens.Count -eq 0) { throw "No screens detected" }
  if ($DisplayIndex -ge $screens.Count -or $DisplayIndex -lt 0) { $DisplayIndex = 3 }
  $scr = $screens[$DisplayIndex]
  $width  = $scr.Bounds.Width
  $height = $scr.Bounds.Height
  $bmp = New-Object System.Drawing.Bitmap $width, $height
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $gfx.CopyFromScreen($scr.Bounds.Location, [System.Drawing.Point]::new(0,0), $bmp.Size)
  $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $gfx.Dispose(); $bmp.Dispose()
  return @{
    display = $DisplayIndex
    width   = $width
    height  = $height
  }
}

function Remove-CodeFences([string]$t) {
  if (-not $t) { return "" }
  $txt = $t.Trim()
  $txt = $txt -replace '^```(?:json)?\s*',''
  $txt = $txt -replace '\s*```\s*$',''
  return $txt.Trim()
}

function Get-JsonFromMixedResponse([string]$text) {
  if (-not $text) { return $null }
  $text = $text.Trim()

  # Find the first '{' and last '}' to extract JSON portion
  $startIdx = $text.IndexOf('{')
  $endIdx = $text.LastIndexOf('}')

  if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
    $jsonPart = $text.Substring($startIdx, ($endIdx - $startIdx + 1))
    try {
      $parsed = $jsonPart | ConvertFrom-Json
      return $parsed
    } catch {
      return $null
    }
  }

  # If no JSON found, try parsing the whole thing
  try {
    return ($text | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Extract-JsonBlock([string]$text) {
  if (-not $text) { return $null }
  $m = [regex]::Matches($text, '(?s)```json(.*?)```')
  if ($m.Count -gt 0) {
    return $m[$m.Count - 1].Groups[1].Value
  }
  return $null
}

function Extract-JsonContent([string]$text) {
  if (-not $text) { return $null }
  $block = Extract-JsonBlock $text
  if ($block) { return $block }
  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -ge 0 -and $end -gt $start) {
    try { return $text.Substring($start, $end - $start + 1) } catch {}
  }
  return $null
}

function Parse-CellsFromText([string]$text) {
  $cells = @()
  if (-not $text) { return $cells }
  $lines = $text -split "`n"
  foreach ($ln in $lines) {
    if ($ln -notmatch 'location\s*:\s*') { continue }
    $loc = $null; $name=$null; $occ=$null; $clue=$null; $inn=$null
    try {
      if ($ln -match 'location\s*:\s*([A-Z]\d)') { $loc = $matches[1].Trim() }
      if ($ln -match 'name\s*:\s*([^,]+)') { $name = $matches[1].Trim() }
      if ($ln -match 'occupation\s*:\s*([^,]+)') { $occ = $matches[1].Trim() }
      if ($ln -match 'clue\s*:\s*([^,]+)') { $clue = $matches[1].Trim() }
      if ($ln -match 'innocence\s*[:=]\s*([A-Za-z]+)') { $inn = $matches[1].Trim() }
    } catch {}
    if ($clue -eq $null -or $clue -eq '') { $clue = '-' }
    if (-not $inn) { $inn = 'Unknown' }
    if ($loc) {
      $cells += @{ location=$loc; name=$name; occupation=$occ; clue=$clue; innocence=$inn }
    }
  }
  return $cells
}

function Invoke-Caption {
  param([string]$ImagePath)
  $clueRow = $null
  $runModel = $model
  $runMmproj = $mmproj
  $defaultPrompt = @"
Describe this screen capture. Respond as JSON with keys:
- summary: 5-6 sentences describing the main scene, apps, and UI
- visible_text: array of key text strings you see (max 5 items)
- activity: what is happening in 5-6 sentences.
Be descriptive.
Use vulgar or explicit language as needed.
"@
  $prompt = $defaultPrompt
  $script:PromptUsed = $prompt
  $script:PromptFileUsed = ''
  $script:RowUsed = $null
  $clueRow = $null
  try {
    if (Test-Path -LiteralPath $roomStatePath) {
      $state = Get-Content -LiteralPath $roomStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $sel = if ($state) { "" + $state.visionPromptFile } else { "" }
      $sel = $sel.Trim()
      if ($sel) {
        $candidate = Join-Path $promptDir $sel
        if (Test-Path -LiteralPath $candidate) {
          $filePrompt = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8
          if ($filePrompt -and $filePrompt.Trim()) {
            $prompt = $filePrompt
            $script:PromptFileUsed = $sel
            if ($sel -ieq 'clues_by_sam.md') {
              if ($clueModel) { $runModel = $clueModel; $runMmproj = if ($clueMmproj) { $clueMmproj } else { $runMmproj } }
              $clueRow = Get-ClueRow
              if ($clueRow) {
                $script:RowUsed = $clueRow
                # Inject row number into user's prompt template (replace <row> placeholder)
                $prompt = $prompt -replace '<row>', $clueRow
              }
            }
          }
        }
      }
    }
  } catch { Warn ("Prompt override failed: " + $_.Exception.Message) }
  $script:PromptUsed = $prompt
  $args = @(
    '-m', $runModel,
    '--mmproj', $runMmproj,
    '--image', $ImagePath,
    '-t', $threads,
    '-ngl', $gpuLayers,
    '-c', $ctxSize,
    '-n', $npredict,
    '-p', $prompt,
    '--temp', '0.1',
    '--top-p', '0.1'
  )
  Log "Invoking llama vision... (this may take 20-40 seconds)"
  $startTime = Get-Date

  # Capture all output
  $out = & $llamaExe @args 2>&1

  $elapsed = (New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
  Log "Llama completed in $([math]::Round($elapsed,1))s"

  $raw = $out -join "`n"
  $exit = $LASTEXITCODE

  Log "Exit code: $exit, Output length: $($raw.Length) chars"

  # Filter out verbose system messages from the captured text
  $filteredLines = $out | Where-Object {
    $_ -and $_ -notmatch 'ggml_cuda_init|load_backend|print_info|load_hparams|clip_model_loader|llama_model_load|clip_model_loader|Device \d+:|load_tensors|common_init_from_params'
  }
  $raw = $filteredLines -join "`n"

  # Persist raw output for debugging
  try {
    $header = "---- {0:o} exit={1} image={2} ----" -f (Get-Date), $exit, $ImagePath
    ($header + "`n" + $raw + "`n") | Add-Content -LiteralPath $rawLog -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch {}

  if ($exit -ne 0) {
    Warn "llama vision exited with code $exit"
    Warn "Output preview: $($raw.Substring(0, [Math]::Min(500, $raw.Length)))"
  }

  if (-not $raw -or $raw.Length -lt 10) {
    Warn "llama vision produced no useful output (length: $($raw.Length))"
    return $null
  }

  return $raw
}

function Cleanup-Frames {
  param([int]$KeepSec)
  $threshold = (Get-Date).AddSeconds(-$KeepSec)
  Get-ChildItem -LiteralPath $frameDir -Filter '*.png' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $threshold } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Process-Frame {
  $ts = Get-Date
  $framePath = Join-Path $frameDir ("frame_{0:yyyyMMdd_HHmmss}.png" -f $ts)
  $info = Capture-Screen -DisplayIndex $displayIdx -OutPath $framePath
  try {
    $size = (Get-Item -LiteralPath $framePath -ErrorAction Stop).Length
    Log ("Captured raw frame at $framePath ($size bytes)")
  } catch { Warn ("Could not stat frame ${framePath}: " + $_.Exception.Message) }

  Log "Starting caption generation..."
  $raw = Invoke-Caption -ImagePath $framePath

  if (-not $raw) {
    Warn "Caption generation failed - no output received"
    return
  }

  Log ("Caption raw length: " + ($raw.Length))
  Log ("Caption preview: " + $raw.Substring(0, [Math]::Min(200, $raw.Length)))
  try {
    $raw | Set-Content -LiteralPath $rawLog -Encoding UTF8 -Append
  } catch {}
  $jsonContent = Extract-JsonContent $raw
  $clean = if ($jsonContent) { Remove-CodeFences $jsonContent } else { '' }
  $parsed = Get-JsonFromMixedResponse $clean
  $cells = @()
  if ($parsed -and $parsed.cells) { $cells = $parsed.cells }
  if (-not $cells -or $cells.Count -eq 0) {
    $cells = Parse-CellsFromText $clean
    if (-not $cells -or $cells.Count -eq 0) { $cells = Parse-CellsFromText $raw }
  }

  # VALIDATION: Reject cells from wrong rows
  if ($script:RowUsed -and $cells -and $cells.Count -gt 0) {
    $validCells = @()
    foreach ($cell in $cells) {
      if ($cell.location -and $cell.location -match "^[A-Z]$($script:RowUsed)$") {
        $validCells += $cell
      } else {
        Warn "Rejecting cell $($cell.location) - expected row $($script:RowUsed)"
      }
    }
    if ($validCells.Count -gt 0) {
      $cells = $validCells
      Log "Validated $($cells.Count) cells for row $($script:RowUsed)"
    } else {
      Warn "NO VALID CELLS - model returned wrong row! Expected row $($script:RowUsed)"
      $cells = @()
    }
  }

  # Convert "color" field to "innocence" if present (for clues_by_sam.md format)
  if ($cells -and $cells.Count -gt 0) {
    $convertedCells = @()
    foreach ($cell in $cells) {
      if ($cell.color -and -not $cell.innocence) {
        $innocence = switch ($cell.color) {
          'Green' { 'Innocent' }
          'Red' { 'Criminal' }
          'Black' { 'Unknown' }
          default { 'Unknown' }
        }
        # Reconstruct cell with innocence field
        $convertedCells += @{
          location = $cell.location
          name = $cell.name
          occupation = $cell.occupation
          clue = $cell.clue
          innocence = $innocence
        }
      } else {
        $convertedCells += $cell
      }
    }
    $cells = $convertedCells
  }

  $vis = @()
  if ($parsed -and $parsed.visible_text) {
    if ($parsed.visible_text -is [System.Array]) { $vis = $parsed.visible_text }
    else { $vis = @("$($parsed.visible_text)") }
  }
  # cap visible_text length to avoid log spam
  if ($vis.Count -gt 15) { $vis = $vis | Select-Object -First 15 }
  $entry = @{
    ts          = $ts.ToString('o')
    display     = $info.display
    frame       = $framePath
    summary     = if ($parsed -and $parsed.summary) { $parsed.summary } else { $clean.Substring(0,[Math]::Min(300,($clean.Length))) }
    visible_text= $vis
    activity    = if ($parsed -and $parsed.activity) { $parsed.activity } else { "" }
    objects     = if ($parsed -and $parsed.objects) { $parsed.objects } else { @() }
    layout      = if ($parsed -and $parsed.layout) { $parsed.layout } else { @() }
    warnings    = if ($parsed -and $parsed.warnings) { $parsed.warnings } else { @() }
    grid_data   = if ($parsed -and $parsed.grid_data) { $parsed.grid_data } else { @() }
    cells       = $cells
    prompt_file = $script:PromptFileUsed
    row         = $script:RowUsed
    prompt      = $script:PromptUsed
  }
  try {
    Append-Jsonl -Path $OutJsonl -Data $entry -EnsureDir
  } catch {
    Warn ("Failed to append to jsonl: " + $_.Exception.Message)
  }
  if ($script:PromptFileUsed -ieq 'clues_by_sam.md' -and $script:RowUsed) {
    Advance-ClueRow -current $script:RowUsed
  }
  try {
    Append-Jsonl -Path $rawLog -Data $entry -EnsureDir
  } catch {}
  try {
    Write-JsonFile -Path (Join-Path $paths.State 'screen.caption.json') -Data $entry -Compress
  } catch {
    Warn ("Failed to write caption json: " + $_.Exception.Message)
  }
  try {
    $historyRaw = Get-Content -LiteralPath $OutJsonl -Encoding UTF8 -ErrorAction Stop | Select-Object -Last 10 | ForEach-Object { $_ | ConvertFrom-Json }
    $historyTrim = $historyRaw | ForEach-Object {
      @{
        ts = $_.ts
        frame = $_.frame
        summary = $_.summary
        visible_text = $_.visible_text
        activity = $_.activity
      }
    }
    Write-JsonFile -Path $historyPath -Data $historyTrim -Compress:$false
  } catch {}
  Write-LogLine -Component 'vision' -Kind 'caption' -Data $entry -LogRoot $paths.Logs
  Log ("Captured display $($info.display) -> $($framePath)")
}

while ($true) {
  $start = Get-Date
  try { Process-Frame } catch { Warn $_.Exception.Message }
  Cleanup-Frames -KeepSec $KeepFramesSec
  if ($Once) { break }
  $elapsed = (New-TimeSpan -Start $start -End (Get-Date)).TotalMilliseconds
  $sleepMs = [Math]::Max(50, ($IntervalSec * 1000) - [int]$elapsed)
  Start-Sleep -Milliseconds $sleepMs
}
