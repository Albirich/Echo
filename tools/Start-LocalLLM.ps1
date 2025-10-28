param(
  [Parameter(Mandatory=$true)][string]$PromptFile,
  [string]$ModelPath = "D:\Echo\models\athirdpath-NSFW_DPO_Noromaid-7b-Q6_K.gguf",
  [string]$LlamaExe  = "D:\llama-cpp\llama-cli.exe",
  [int]$CtxSize      = 4096,
  [int]$GpuLayers    = 40,
  [int]$MaxTokens    = 1024,
  [double]$Temp      = 0.7,
  [switch]$FlashAttn,
  [string[]]$Images,
  [string]$Mmproj,
  [switch]$JsonOut
)
$ErrorActionPreference = "Stop"
$ECHO  = if ($env:ECHO_HOME -and (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME } else { "D:\Echo" }
$Logs  = Join-Path $ECHO "logs"; New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$Outbx = Join-Path $ECHO "ui\outbox.jsonl"; if (!(Test-Path $Outbx)) { New-Item -ItemType File -Force -Path $Outbx | Out-Null }

$ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss_fff"
$logF = Join-Path $Logs "llama-$ts-$PID.log"
$errF = Join-Path $Logs "llama-$ts-$PID.err.log"

# Optional thread cap via env
$llamaThreads = 0
try { if ($env:ECHO_LLAMA_THREADS -and $env:ECHO_LLAMA_THREADS.Trim()) { $llamaThreads = [int]$env:ECHO_LLAMA_THREADS } } catch {}
try { if ($llamaThreads -le 0 -and $env:ECHO_IM_THREADS -and $env:ECHO_IM_THREADS.Trim()) { $llamaThreads = [int]$env:ECHO_IM_THREADS } } catch {}

# Optional GPU layer override via env (if set)
try { if ($env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { $GpuLayers = [int]$env:ECHO_LLAMA_GPU_LAYERS } } catch {}
try { if ($env:ECHO_IM_GPU_LAYERS -and $env:ECHO_IM_GPU_LAYERS.Trim()) { $GpuLayers = [int]$env:ECHO_IM_GPU_LAYERS } } catch {}

# Optional context size override via env (if set)
try { if ($env:ECHO_LLAMA_CTX -and $env:ECHO_LLAMA_CTX.Trim()) { $CtxSize = [int]$env:ECHO_LLAMA_CTX } } catch {}
try { if ($env:ECHO_IM_CTX -and $env:ECHO_IM_CTX.Trim()) { $CtxSize = [int]$env:ECHO_IM_CTX } } catch {}

# Optional mmproj override via env (if not explicitly provided)
if (-not $Mmproj -and $env:ECHO_VISION_MMPROJ) {
  try {
    $p = $env:ECHO_VISION_MMPROJ
    $invalid = [System.IO.Path]::GetInvalidPathChars()
    if ($p -and $p.IndexOfAny($invalid) -eq -1 -and (Test-Path -LiteralPath $p)) { $Mmproj = $p }
  } catch {}
}

# Build args with compatibility for different llama binaries
function Get-LlamaArgs {
  param(
    [string]$Exe,[string]$Model,[int]$Ctx,[int]$Gpu,[int]$Max,[double]$Temperature,[string]$Prompt,[switch]$Flash,[string[]]$Imgs,[string]$Mm,[switch]$WantJson
  )
  $help = ''
  try { $help = (& $Exe -h 2>&1 | Out-String) } catch { try { $help = (& $Exe --help 2>&1 | Out-String) } catch { $help = '' } }
  $leaf = try { (Split-Path -Leaf $Exe) } catch { '' }
  $isMtmd = ($leaf -ieq 'llama-mtmd-cli.exe' -or $help -like '*Experimental CLI for multimodal*')
  $useLong = ($help -like '*--prompt-file*')
  $hasNoDisplay = ($help -like '*--no-display-prompt*')
  $hasFlash = ($help -like '*--flash-attn*')
  $hasNoCnv = ($help -like '*-no-cnv*' -or $help -like '*--no-cnv*')
  $hasGrammarJson = ($help -like '*--grammar-json*')
  $hasImage = ($help -like '*--image*' -or $help -like '*-i, --image*') -or $isMtmd
  $hasMmproj = ($help -like '*--mmproj*') -or $isMtmd
  $hasMainGpu = ($help -like '*--main-gpu*' -or $help -like '*-mg, --main-gpu*')
  $hasBatch = ($help -like '*--batch-size*' -or $help -like '*-b, --batch-size*' -or $help -like '*--batch *')
  $hasUBatch = ($help -like '*--ubatch-size*' -or $help -like '*-ub, --ubatch-size*' -or $help -like '*--ubatch *')

  if ($isMtmd) {
    $a = @("-m", $Model, "--ctx-size", $Ctx, "--n-gpu-layers", $Gpu, "--n-predict", $Max, "--temp", $Temperature)
    # mtmd CLI: use -f for prompt; no explicit stop flag
    $a += @("-f", $Prompt)
    # vision flags handled below
  } else {
    $a = @("-m", $Model, "--ctx-size", $Ctx, "--n-gpu-layers", $Gpu, "--n-predict", $Max, "--temp", $Temperature)
    if ($useLong) {
    # Do not enable --verbose-prompt to avoid echoing prompt to STDOUT
    $a += @("--prompt-file", $Prompt)
    if ($hasNoDisplay) { $a += "--no-display-prompt" }
    # Only stop on assistant end token so generation proceeds
    $a += @("--stop", "<|im_end|>")
    # IMPORTANT: Do NOT auto-append -no-cnv here; leave chat templating enabled by default.
  } else {
    # Fallback to short flags commonly supported by older/main builds
    $a += @("-f", $Prompt, "-r", "<|im_end|>")
  }
  }
  # If JSON requested, aggressively disable chat templating; fallback handled after run if unsupported
  if ($WantJson -and -not ($a -contains '-no-cnv')) { $a += '-no-cnv' }
  # If caller requests strict JSON and binary supports it, constrain output
  if ($WantJson -and $hasGrammarJson) { $a += @('--grammar-json') }
  if ($Flash -and $hasFlash) { $a += @("--flash-attn") }
  
  # Optional perf knobs
  try {
    $mainGpu = 0; if ($env:ECHO_LLAMA_MAIN_GPU -and $env:ECHO_LLAMA_MAIN_GPU.Trim()) { $mainGpu = [int]$env:ECHO_LLAMA_MAIN_GPU }
  } catch { $mainGpu = 0 }
  try {
    $batch = 0; if ($env:ECHO_LLAMA_BATCH -and $env:ECHO_LLAMA_BATCH.Trim()) { $batch = [int]$env:ECHO_LLAMA_BATCH }
  } catch { $batch = 0 }
  try {
    $ubatch = 0; if ($env:ECHO_LLAMA_UBATCH -and $env:ECHO_LLAMA_UBATCH.Trim()) { $ubatch = [int]$env:ECHO_LLAMA_UBATCH }
  } catch { $ubatch = 0 }
  if ($hasMainGpu) { $a += @('--main-gpu', $mainGpu) }
  if ($hasBatch -and $batch -gt 0) { $a += @('--batch-size', $batch) }
  if ($hasUBatch -and $ubatch -gt 0) { $a += @('--ubatch-size', $ubatch) }
  
  # Vision: attach images and optional mmproj if supported
  if ($Imgs -and $Imgs.Count -gt 0 -and $hasImage) {
    foreach ($img in $Imgs) {
      if ($img -and (Test-Path $img)) { $a += @('--image', $img) }
    }
  }
  if ($Mm -and $hasMmproj -and (Test-Path $Mm)) {
    $a += @('--mmproj', $Mm)
  }
  return ,$a
}

$args = Get-LlamaArgs -Exe $LlamaExe -Model $ModelPath -Ctx $CtxSize -Gpu $GpuLayers -Max $MaxTokens -Temperature $Temp -Prompt $PromptFile -Flash:$FlashAttn -Imgs $Images -Mm $Mmproj -WantJson:$JsonOut

# Append threads flag if requested
if ($llamaThreads -gt 0) {
  $help = ''
  try { $help = (& $LlamaExe -h 2>&1 | Out-String) } catch { try { $help = (& $LlamaExe --help 2>&1 | Out-String) } catch { $help = '' } }
  $hasThreadsShort = ($help -like '* -t *' -or $help -like '*-t, --threads*')
  $hasThreadsLong  = ($help -like '*--threads*')
  if ($hasThreadsShort) { $args += @('-t', $llamaThreads) }
  elseif ($hasThreadsLong) { $args += @('--threads', $llamaThreads) }
}

# Optional override to force disabling chat templating regardless of help detection
# Only append if the binary actually supports it; mtmd builds typically do not.
if ($env:ECHO_LLAMA_NO_CNV -and ($env:ECHO_LLAMA_NO_CNV -match '^(1|true|yes)$')) {
  $help2 = ''
  try { $help2 = (& $LlamaExe -h 2>&1 | Out-String) } catch { try { $help2 = (& $LlamaExe --help 2>&1 | Out-String) } catch { $help2 = '' } }
  $supportsNoCnv = ($help2 -like '*-no-cnv*' -or $help2 -like '*--no-cnv*')
  if ($supportsNoCnv -and -not ($args -contains '-no-cnv')) {
    $args += '-no-cnv'
  }
}

$hdr = @"
==== llama.cpp RUN ====
Time:        $ts
Model:       $ModelPath
Ctx:         $CtxSize
GPU layers:  $GpuLayers
Threads:     $llamaThreads
Max tokens:  $MaxTokens
Temp:        $Temp
PromptFile:  $PromptFile
Args:        $($args -join ' ')
Log:         $logF
=======================
"@
[IO.File]::WriteAllText($logF, $hdr, [Text.UTF8Encoding]::new($false))

# Capture exact prompt text for logging and bus record
try {
  $promptText = [System.IO.File]::ReadAllText($PromptFile, [System.Text.UTF8Encoding]::new($false))
} catch {
  $promptText = try { Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8 } catch { '' }
}
try {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($promptText)
  $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
} catch { $hash = '' }

"`n---- PROMPT (UTF8) BEGIN ----`n$promptText`n---- PROMPT (UTF8) END ----`n" | Add-Content -LiteralPath $logF -Encoding UTF8

# Run model. Send STDERR only to log file so user output stays clean.
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$exit = 0
try {
  try {
    # Send STDERR to a temp file to avoid write-handle conflicts with Tee-Object.
    # Tee STDOUT to the log file for a unified log after we append STDERR.
    $gen  = & $LlamaExe @args 2> $errF | Tee-Object -FilePath $logF
    $text = ($gen | Out-String)
    $exit = $LASTEXITCODE
    # If CLI fails and -no-cnv was passed, retry once without it (older builds)
    if ($exit -ne 0 -and ($args -contains '-no-cnv')) {
      $args2 = @($args | Where-Object { $_ -ne '-no-cnv' })
      if ($args2.Count -gt 0) {
        "`n---- RETRY without -no-cnv ----`n" | Add-Content -LiteralPath $logF -Encoding UTF8
        $gen2  = & $LlamaExe @args2 2>> $errF | Tee-Object -FilePath $logF
        $text2 = ($gen2 | Out-String)
        $exit2 = $LASTEXITCODE
        if ($exit2 -eq 0 -and $text2) { $text = $text2; $exit = 0; $args = $args2 }
      }
    }
  } catch {
    $text = ("ERROR: {0}" -f $_.Exception.Message)
    $exit = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
  }
} finally {
  $ErrorActionPreference = $oldEap
}
"`n---- llama.cpp EXIT: $exit ----`n" | Add-Content -LiteralPath $logF -Encoding UTF8

# Append captured STDERR to the log (then remove the temp)
try {
  if (Test-Path -LiteralPath $errF) {
    "`n---- STDERR BEGIN ----`n" | Add-Content -LiteralPath $logF -Encoding UTF8
    try { Get-Content -LiteralPath $errF -Raw -Encoding UTF8 | Add-Content -LiteralPath $logF -Encoding UTF8 } catch {}
    "`n---- STDERR END ----`n"   | Add-Content -LiteralPath $logF -Encoding UTF8
    Remove-Item -LiteralPath $errF -Force -ErrorAction SilentlyContinue
  }
} catch {}

# Clean output: keep only model's assistant message
# 1) Normalize newlines
$clean = ($text -replace "\r\n?","`n")

# 2) If the binary echoed the prompt, drop everything up to and including the last assistant marker
$assistantTag = '<|im_start|>assistant'
$idx = $clean.LastIndexOf($assistantTag)
if ($idx -ge 0) {
  $clean = $clean.Substring($idx + $assistantTag.Length)
  if ($clean.StartsWith("`n")) { $clean = $clean.Substring(1) }
}

# 3) Stop at the first end tag if present
$endTag = '<|im_end|>'
$endIdx = $clean.IndexOf($endTag)
if ($endIdx -ge 0) { $clean = $clean.Substring(0, $endIdx) }

# 4) Handle non-ChatML templates that prefix with literal 'user'/'assistant' lines
try {
  $m = [regex]::Match($clean, '(?ms)^(?:\s*user\s*\n)(.*?)(?:\n\s*assistant\s*\n)([\s\S]*)$')
  if ($m.Success) { $clean = $m.Groups[2].Value }
} catch {}

# 5) If prompt text was echoed, remove it from the head (exact or per-line)
try {
  $pt = ($promptText -replace "\r\n?","`n")
  $cl = $clean
  if ($pt) {
    # Exact prefix match
    if ($cl.StartsWith($pt)) {
      $cl = $cl.Substring($pt.Length)
      $cl = $cl.TrimStart(" `t`r`n")
    } else {
      # Line-by-line prefix trim
      $ptLines = @($pt -split "`n")
      $clLines = @($cl -split "`n")
      $i = 0
      while ($i -lt $ptLines.Count -and $i -lt $clLines.Count -and ($ptLines[$i].Trim() -eq $clLines[$i].Trim())) { $i++ }
      if ($i -gt 0) { $cl = ($clLines[$i..($clLines.Count-1)] -join "`n") }
    }
  }
  $clean = $cl
} catch {}

# 6) Trim any stray init/perf lines and prompt echoes
$lines = $clean -split "`n"
$lines = $lines | Where-Object {
  ($_ -ne '') -and
  -not ($_ -match '^(Device \d+:|build: |PEER_MAX_BATCH_SIZE =|LLAMAFILE =|OPENMP =)') -and
  -not ($_ -match '^(repeat_last_n|dry_multiplier|top_k|mirostat)') -and
  -not ($_ -match '^(ggml_|load_backend:|system_info:|llama_|sampler:)') -and
  -not ($_ -match '^(main:|encoding image slice|image slice encoded|decoding image batch|image decoded)') -and
  -not ($_ -match '^\s*unaccounted \|')
}
$lines = $lines | Where-Object { -not ($_ -match '^(user|assistant|system)\s*$') }
$lines = $lines | Where-Object { -not ($_ -match '^(?:>\s*)?EOF by user' ) -and -not ($_ -match '^(?:>\s*)?Interrupted by user') }
$clean = ($lines -join "`n").Trim()

# 7) If the remaining text still looks like instruction-only content, clear it
#    Skip this for vision calls (images provided) or when disabled via env.
try {
  $skipInstrClean = $false
  try { if ($env:ECHO_VISION_NO_INSTR_CLEAN -and ($env:ECHO_VISION_NO_INSTR_CLEAN -match '^(1|true|yes)$')) { $skipInstrClean = $true } } catch {}
  try { if ($env:ECHO_CHAT_NO_INSTR_CLEAN -and ($env:ECHO_CHAT_NO_INSTR_CLEAN -match '^(1|true|yes)$')) { $skipInstrClean = $true } } catch {}
  if (-not $skipInstrClean) {
    if ($Images -and $Images.Count -gt 0) { $skipInstrClean = $true }
  }
  if (-not $skipInstrClean) {
    $low = $clean.ToLower()
    if ($low -match '^\s*(describe the screenshot|you are describing a screenshot|write\s+\d+\D{0,3}\d+\s+short sentences|format as:|ensure all texts|avoid mentioning|no speculation)') {
      $clean = ''
    }
  }
} catch {}

# Append JSONL to the Echo bus (with simple retry if locked)
$rec = [ordered]@{
  ts     = (Get-Date).ToString("o")
  source = "llama.cpp"
  model  = (Split-Path $ModelPath -Leaf)
  ctx    = $CtxSize; gpu = $GpuLayers; temp = $Temp
  log    = $logF
  input  = $PromptFile
  prompt = $promptText
  prompt_len = ($promptText.Length)
  prompt_sha256 = $hash
  args   = ($args -join ' ')
  exit_code = $exit
  text   = $clean
}
try {
  $runOut = try { Get-Content -Raw -LiteralPath $logF } catch { '' }
  $backend = if ($runOut -match 'loaded CUDA backend') { 'cuda' }
             elseif ($runOut -match 'loaded Vulkan backend') { 'vulkan' }
             elseif ($runOut -match 'loaded METAL backend') { 'metal' }
             elseif ($runOut -match 'loaded DML backend') { 'directml' }
             elseif ($runOut -match 'loaded OpenCL backend') { 'opencl' }
             elseif ($runOut -match 'loaded CPU backend') { 'cpu' }
             else { 'unknown' }
  $rec.gpu_backend = $backend
  $rec.gpu_used = ($backend -ne 'cpu' -and $backend -ne 'unknown')
  # Also include a small tail of the raw stdout/stderr log for debugging when text is empty
  try {
    if ($runOut) {
      $tail = $runOut
      if ($tail.Length -gt 1200) { $tail = $tail.Substring([Math]::Max(0, $tail.Length-1200)) }
      $rec.stdout_tail = $tail
    }
  } catch {}
} catch { }
function Add-JsonlSafe([string]$Path,[string]$Line,[int]$Retries=3){
  # Ensure no BOM at line start
  if ($Line -and $Line.Length -gt 0 -and [int][char]$Line[0] -eq 0xFEFF) {
    $Line = $Line.Substring(1)
  }
  $attempt = 0
  while ($attempt -le $Retries) {
    try {
      $sw = New-Object IO.StreamWriter($Path, $true, [Text.UTF8Encoding]::new($false))
      try { $sw.WriteLine($Line) } finally { $sw.Dispose() }
      return
    } catch {
      Start-Sleep -Milliseconds 50
      $attempt++
    }
  }
}
$line = ($rec | ConvertTo-Json -Compress -Depth 5)
Add-JsonlSafe -Path $Outbx -Line $line

# Persist a debug snapshot for callers to inspect (non-STDOUT)
try {
  $dbgDir = Join-Path $ECHO 'debug'; if (-not (Test-Path $dbgDir)) { New-Item -ItemType Directory -Force -Path $dbgDir | Out-Null }
  [IO.File]::WriteAllText((Join-Path $dbgDir 'last-llama.json'), ($rec | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
} catch {}

# Do not print anything except the cleaned model text to STDOUT; emit the generated text for callers
Write-Output $clean
