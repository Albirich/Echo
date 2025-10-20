param(
  [string]$WhisperExe = "C:\ai\whisper\Release-cublas\stream.exe",
  [string]$Model      = "C:\ai\models\ggml-tiny.en.bin",
  [int]$MicIndex      = -1,
  [string]$EchoHome   = $env:ECHO_HOME,
  [string]$UserName   = "user",
  [switch]$UseGPU,           # if present, prefer GPU and offload layers
  [switch]$NoGPU,            # force CPU-only (overrides UseGPU)
  [int]$Threads = 0,         # worker threads; 0 = let binary decide
  [switch]$FlashAttn,        # enable flash attention (GPU builds)
  [switch]$NoRestart,        # disable keep-alive restarts
  [int]$RestartDelaySec = 3, # delay before restart on exit
  [int]$StartupGraceMs = 1500, # if the process exits within this, treat as startup failure
  [int[]]$MicCandidates,     # optional list of mic indices to try; default: -1,0..5 when MicIndex=-1
  [int]$GpuLayers = 0,       # if >0, pass -ngl to whisper-stream
  [int]$EndSilenceMs = 1000, # trailing silence required before flush (ms)
  [switch]$FlushOnPunct      # optionally flush when line ends with punctuation
)

if (-not $EchoHome) { $EchoHome = "D:\Echo" }
$Inbox = Join-Path $EchoHome "ui\inboxq"
New-Item -ItemType Directory -Force -Path $Inbox | Out-Null

if (-not (Test-Path $WhisperExe)) { throw "whisper-stream not found: $WhisperExe" }
if (-not (Test-Path $Model))      { throw "Model not found: $Model" }

[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

if (-not $MicCandidates -or $MicCandidates.Count -eq 0) {
  if ($MicIndex -eq -1) { $MicCandidates = @(-1,0,1,2,3,4,5) } else { $MicCandidates = @($MicIndex) }
}

Write-Host ("whisper-stream launcher ready. Model={0}  Candidates=[{1}]" -f $Model, ($MicCandidates -join ',')) -ForegroundColor Green

# Normalize GPU intent from env fallbacks, unless explicitly set
try {
  if ($GpuLayers -le 0 -and $env:ECHO_WHISPER_NGL -and $env:ECHO_WHISPER_NGL.Trim()) { $GpuLayers = [int]$env:ECHO_WHISPER_NGL }
} catch {}
try {
  if ($GpuLayers -le 0 -and $env:ECHO_IM_GPU_LAYERS -and $env:ECHO_IM_GPU_LAYERS.Trim()) { $GpuLayers = [int]$env:ECHO_IM_GPU_LAYERS }
} catch {}
try {
  if ($GpuLayers -le 0 -and $env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) { $GpuLayers = [int]$env:ECHO_LLAMA_GPU_LAYERS }
} catch {}

# Detect target binary flavor (whisper.cpp 'stream.exe' vs custom 'whisper-stream.exe')
$exeName = [IO.Path]::GetFileName($WhisperExe).ToLowerInvariant()
$isWhisperCppStream = ($exeName -eq 'stream.exe' -or $exeName -like 'stream-*.exe')

if ($NoGPU) {
  Write-Host "GPU: disabled (--no-gpu)" -ForegroundColor Yellow
} elseif (-not $isWhisperCppStream -and $GpuLayers -gt 0) {
  Write-Host ("GPU: requested (-ngl {0})" -f $GpuLayers) -ForegroundColor Green
} elseif ($UseGPU) {
  if (-not $isWhisperCppStream) {
    if ($GpuLayers -le 0) { $GpuLayers = 999 }
    Write-Host ("GPU: requested (no layers specified; using -ngl {0})" -f $GpuLayers) -ForegroundColor Green
  } else {
    Write-Host "GPU: requested (whisper.cpp stream enables GPU by default)" -ForegroundColor Green
  }
} else {
  Write-Host "GPU: preferred (if supported by build)" -ForegroundColor Green
}
if ($Threads -gt 0) { Write-Host ("Threads: {0}" -f $Threads) -ForegroundColor Green }
if ($FlashAttn) { Write-Host "Flash Attention: enabled" -ForegroundColor Green }
Write-Host "Piping recognized utterances into $Inbox" -ForegroundColor Green

# --- helpers ---
$ansi = "[\u001B\u009B][\[()#;?]*(?:\d{1,4}(?:;\d{0,4})*)?[0-9A-ORZcf-nqry=><]"
function Clean-Line([string]$s) {
  if (-not $s) { return "" }
  $s = $s -replace $ansi, ""           # strip ANSI control
  $s = $s -replace "`r",""             # strip CR
  return $s.Trim()
}

function QuoteIfNeeded([string]$s) {
  if (-not $s) { return '""' }
  $t = $s.Trim()
  if ($t -match '\s') { return '"' + $t + '"' } else { return $t }
}

$buf = ""
$lastSent = ""
# Track latest time we appended recognized speech to the buffer
$script:lastVoiceAt = $null

function Flush-Buf([string]$reason) {
  $text = $script:buf.Trim()
  if ($text.Length -lt 3) { $script:buf = ""; $script:lastVoiceAt = $null; return }
  if ($text -eq $script:lastSent) { $script:buf = ""; return } # drop duplicates

  $ts = (Get-Date).ToString("yyyyMMdd-HHmmss-fff")
  $path = Join-Path $Inbox "$ts`_$UserName.txt"
  Set-Content -Path $path -Value $text -NoNewline -Encoding UTF8
  Write-Host "[sent:$reason] $text" -ForegroundColor Cyan
  $script:lastSent = $text
  $script:buf = ""
  $script:lastVoiceAt = $null
}

# Keep-alive loop
while ($true) {
  foreach ($mic in $MicCandidates) {
    # Build process start info for this attempt
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WhisperExe

    $argList = @()
    $argList += @('-m', (QuoteIfNeeded $Model))
    $argList += @('-c', $mic)
    if ($Threads -gt 0) { $argList += @('-t', $Threads) }
    if ($NoGPU.IsPresent) {
      # whisper.cpp stream uses -ng / --no-gpu to disable GPU
      if ($isWhisperCppStream) { $argList += @('-ng') } else { $argList += '--no-gpu' }
    } elseif (-not $isWhisperCppStream -and $GpuLayers -gt 0) {
      # custom whisper-stream supports -ngl; whisper.cpp stream does not
      $argList += @('-ngl', $GpuLayers)
    }
    # flash-attn is not a whisper.cpp flag; only add for custom builds if requested
    if ($FlashAttn.IsPresent -and -not $isWhisperCppStream) { $argList += '--flash-attn' }

    $psi.Arguments = ($argList -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    Write-Host ("whisper-stream running. Mic={0}  Args={1}" -f $mic, $psi.Arguments) -ForegroundColor Green

    # Quick health check: exit within grace window => treat as startup failure
    if ($p.WaitForExit($StartupGraceMs)) {
      $stderrAll = try { $p.StandardError.ReadToEnd() } catch { '' }
      $stdoutAll = try { $p.StandardOutput.ReadToEnd() } catch { '' }
      Write-Host ("[whisper] exited quickly (code {0}) for Mic={1}" -f $p.ExitCode, $mic) -ForegroundColor Yellow
      if ($stderrAll) { Write-Host "[stderr][startup] $stderrAll" -ForegroundColor Red }
      if ($stdoutAll) { Write-Host "[stdout][startup] $stdoutAll" -ForegroundColor DarkYellow }
      # try next candidate
      continue
    }

    # Attach IO
    $stdout = $p.StandardOutput
    $stderr = $p.StandardError

    # echo stderr so we see runtime errors
    $stderrJob = Start-Job -ScriptBlock {
      param($h)
      while ($true) {
        if (-not $h.EndOfStream) {
          $line = $h.ReadLine()
          if ($line) { Write-Host "[stderr] $line" -ForegroundColor Red }
        } else { Start-Sleep -Milliseconds 50 }
      }
    } -ArgumentList $stderr

    # --- read loop ---
    while (-not $p.HasExited) {
      $raw = $stdout.ReadLine()
      if ($null -eq $raw) { Start-Sleep -Milliseconds 10; continue }
      $line = Clean-Line $raw
      if (-not $line) { continue }

      if ($line -match '^\[\s*(Silence|BLANK_AUDIO)\s*\]$') {
        if ($buf.Trim()) {
          if ($script:lastVoiceAt) {
            $elapsed = [int]((Get-Date) - $script:lastVoiceAt).TotalMilliseconds
            if ($elapsed -ge $EndSilenceMs) {
              Flush-Buf "silence_timeout"
            }
          }
        }
        continue
      }
      # Adapt to whisper.cpp stream output: lines often start with 'text: ...'
      if ($isWhisperCppStream -and $line -match '^text:\s*(.+)$') {
        $line = $Matches[1]
      }
      if ($line -match '^\[[^\]]+\]$') { continue }
      if ($line -match '^(partial:|info:|note:|->)') { continue }
      if ($line -match '^[\.\,\!\?]+$') { continue }
      if ($buf.EndsWith($line)) { continue }

      if ($buf) { $buf += ' ' }
      $buf += $line
      $script:lastVoiceAt = Get-Date
      
      # Optional heuristic: flush when the buffer ends with punctuation (disabled by default)
      if ($FlushOnPunct.IsPresent -and $buf.Length -ge 12 -and $buf -match '[\.!?]$') {
        Flush-Buf "punct"
      }
    }

    # process ended; cleanup and maybe restart
    $exit = $p.ExitCode
    if ($buf.Trim()) { Flush-Buf "exit" }
    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    try { if ($stderrJob) { Stop-Job $stderrJob -Force -ErrorAction SilentlyContinue; Remove-Job $stderrJob -Force -ErrorAction SilentlyContinue } } catch {}

    Write-Host ("[whisper] process exited (code {0}) Mic={1}" -f $exit, $mic) -ForegroundColor Yellow

    if ($NoRestart) { return }
    Write-Host ("[whisper] restarting in {0}s..." -f $RestartDelaySec) -ForegroundColor Yellow
    Start-Sleep -Seconds $RestartDelaySec
    # On restart, prefer the last known-good mic (same mic index)
    $MicCandidates = @($mic)
  }

  # If we exhausted candidates without a stable start and NoRestart is set, bail out
  if ($NoRestart) { break }
  Write-Host ("[whisper] retrying mic candidates after {0}s..." -f $RestartDelaySec) -ForegroundColor Yellow
  Start-Sleep -Seconds $RestartDelaySec
}
