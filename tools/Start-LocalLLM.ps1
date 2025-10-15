param(
  [Parameter(Mandatory=$true)][string]$PromptFile,
  [string]$ModelPath = "D:\Echo\models\athirdpath-NSFW_DPO_Noromaid-7b-Q6_K.gguf",
  [string]$LlamaExe  = "D:\llama-cpp\llama-cli.exe",
  [int]$CtxSize      = 8192,
  [int]$GpuLayers    = 40,
  [int]$MaxTokens    = 1024,
  [double]$Temp      = 0.7,
  [switch]$FlashAttn
)

$ErrorActionPreference = "Stop"
$ECHO  = if ($env:ECHO_HOME -and (Test-Path $env:ECHO_HOME)) { $env:ECHO_HOME } else { "D:\Echo" }
$Logs  = Join-Path $ECHO "logs"; New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$Outbx = Join-Path $ECHO "ui\outbox.jsonl"; if (!(Test-Path $Outbx)) { New-Item -ItemType File -Force -Path $Outbx | Out-Null }

$ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss_fff"
$logF = Join-Path $Logs "llama-$ts-$PID.log"
$errF = Join-Path $Logs "llama-$ts-$PID.err.log"

# Build args with compatibility for different llama binaries
function Get-LlamaArgs {
  param(
    [string]$Exe,[string]$Model,[int]$Ctx,[int]$Gpu,[int]$Max,[double]$Temperature,[string]$Prompt,[switch]$Flash
  )
  $help = ''
  try { $help = (& $Exe -h 2>&1 | Out-String) } catch { try { $help = (& $Exe --help 2>&1 | Out-String) } catch { $help = '' } }
  $useLong = ($help -like '*--prompt-file*')
  $hasNoDisplay = ($help -like '*--no-display-prompt*')
  $hasFlash = ($help -like '*--flash-attn*')
  $hasNoCnv = ($help -like '*-no-cnv*' -or $help -like '*--no-cnv*')

  $a = @("-m", $Model, "--ctx-size", $Ctx, "--n-gpu-layers", $Gpu, "--n-predict", $Max, "--temp", $Temperature)
  if ($useLong) {
    # Do not enable --verbose-prompt to avoid echoing prompt to STDOUT
    $a += @("--prompt-file", $Prompt)
    if ($hasNoDisplay) { $a += "--no-display-prompt" }
    # Only stop on assistant end token so generation proceeds
    $a += @("--stop", "<|im_end|>")
    if ($hasNoCnv) { $a += "-no-cnv" }
  } else {
    # Fallback to short flags commonly supported by older/main builds
    $a += @("-f", $Prompt, "-r", "<|im_end|>")
  }
  if ($Flash -and $hasFlash) { $a += @("--flash-attn") }
  return ,$a
}

$args = Get-LlamaArgs -Exe $LlamaExe -Model $ModelPath -Ctx $CtxSize -Gpu $GpuLayers -Max $MaxTokens -Temperature $Temp -Prompt $PromptFile -Flash:$FlashAttn

# Optional override to force disabling chat templating regardless of help detection
if ($env:ECHO_LLAMA_NO_CNV -and ($env:ECHO_LLAMA_NO_CNV -match '^(1|true|yes)$')) {
  if (-not ($args -contains '-no-cnv')) { $args += '-no-cnv' }
}

$hdr = @"
==== llama.cpp RUN ====
Time:        $ts
Model:       $ModelPath
Ctx:         $CtxSize
GPU layers:  $GpuLayers
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

# 4) Trim any stray init/perf lines that might have slipped through
$lines = $clean -split "`n"
$lines = $lines | Where-Object {
  ($_ -ne '') -and
  -not ($_ -match '^(Device \d+:|build: |PEER_MAX_BATCH_SIZE =|LLAMAFILE =|OPENMP =)') -and
  -not ($_ -match '^(repeat_last_n|dry_multiplier|top_k|mirostat)') -and
  -not ($_ -match '^\s*unaccounted \|')
}
$clean = ($lines -join "`n").Trim()

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

# Do not print anything except the cleaned model text to STDOUT

# Also emit the generated text on STDOUT for callers that capture output
Write-Output $clean

