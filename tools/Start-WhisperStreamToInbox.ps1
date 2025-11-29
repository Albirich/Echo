param(
  [string]$WhisperExe = "C:\ai\whisper\Release-cublas\stream.exe",
  [string]$Model      = "C:\ai\models\ggml-tiny.en.bin",
  [int]$MicIndex      = -1,
  [string]$EchoHome   = $env:ECHO_HOME,
  [string]$UserName   = "user",
  [switch]$UseGPU,           # explicit GPU enable (redundant now, GPU on by default)
  [switch]$NoGPU,            # force CPU-only (overrides default)
  [int]$Threads = 4,         # ✅ CHANGED: Default to 4 threads (was 0)
  [switch]$FlashAttn,        # enable flash attention (GPU builds)
  [switch]$NoRestart,        # disable keep-alive restarts
  [int]$RestartDelaySec = 3,
  [int]$StartupGraceMs = 1500,
  [int[]]$MicCandidates,
  [int]$GpuLayers = 4,       # ✅ CHANGED: Default to 4 GPU layers (was 0)
  [int]$EndSilenceMs = 1000,
  [switch]$FlushOnPunct,
  [int]$OutputTimeoutSec = 30  # ✅ NEW: Watchdog timeout - restart if no output for this long
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

# ✅ IMPROVED: Normalize GPU intent with better defaults
try {
  if ($env:ECHO_WHISPER_NGL -and $env:ECHO_WHISPER_NGL.Trim()) { 
    $GpuLayers = [int]$env:ECHO_WHISPER_NGL 
  }
} catch {}

# If still 0 after env check, use 4 as default (was: leave at 0)
if ($GpuLayers -eq 0 -and -not $NoGPU) { $GpuLayers = 4 }

# Detect binary flavor
$exeName = [IO.Path]::GetFileName($WhisperExe).ToLowerInvariant()
$isWhisperCppStream = ($exeName -eq 'stream.exe' -or $exeName -like 'stream-*.exe')

# ✅ IMPROVED: Better GPU status reporting
if ($NoGPU) {
  $GpuLayers = 0
  Write-Host "GPU: DISABLED (--no-gpu flag)" -ForegroundColor Yellow
} elseif ($GpuLayers -gt 0) {
  Write-Host "GPU: ENABLED with $GpuLayers layers" -ForegroundColor Green
} else {
  Write-Host "GPU: Auto-detect (whisper.cpp default)" -ForegroundColor Cyan
}

if ($Threads -gt 0) { 
  Write-Host "Threads: $Threads (optimized for GPU)" -ForegroundColor Green 
} else {
  Write-Host "Threads: Auto-detect" -ForegroundColor Cyan
}

if ($FlashAttn) { Write-Host "Flash Attention: ENABLED" -ForegroundColor Green }
Write-Host "Watchdog Timeout: ${OutputTimeoutSec}s (auto-restart if hung)" -ForegroundColor Green
Write-Host "Piping recognized utterances into $Inbox" -ForegroundColor Green
Write-Host ""

# Helper functions
$ansi = "[\u001B\u009B][\[()#;?]*(?:\d{1,4}(?:;\d{0,4})*)?[0-9A-ORZcf-nqry=><]"
function Clean-Line([string]$s) {
  if (-not $s) { return "" }
  $s = $s -replace $ansi, ""
  $s = $s -replace "`r",""
  return $s.Trim()
}

function QuoteIfNeeded([string]$s) {
  if (-not $s) { return '""' }
  $t = $s.Trim()
  if ($t -match '\s') { return '"' + $t + '"' } else { return $t }
}

$buf = ""
$lastSent = ""
$script:lastVoiceAt = $null

function Flush-Buf([string]$reason) {
  $text = $script:buf.Trim()
  if ($text.Length -lt 3) { $script:buf = ""; $script:lastVoiceAt = $null; return }
  if ($text -eq $script:lastSent) { $script:buf = ""; return }

  $ts = (Get-Date).ToString("yyyyMMdd-HHmmss-fff")
  $path = Join-Path $Inbox "$ts`_$UserName.txt"
  Set-Content -Path $path -Value $text -NoNewline -Encoding UTF8
  Write-Host "[sent:$reason] $text" -ForegroundColor Cyan
  $script:lastSent = $text
  $script:buf = ""
  $script:lastVoiceAt = $null
}

# Main loop
while ($true) {
  foreach ($mic in $MicCandidates) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WhisperExe

    $argList = @()
    $argList += @('-m', (QuoteIfNeeded $Model))
    $argList += @('-c', $mic)
    
    # ✅ IMPROVED: Always pass threads if set
    if ($Threads -gt 0) { $argList += @('-t', $Threads) }
    
    if ($NoGPU.IsPresent) {
      if ($isWhisperCppStream) { $argList += @('-ng') } else { $argList += '--no-gpu' }
    } elseif (-not $isWhisperCppStream -and $GpuLayers -gt 0) {
      # Custom whisper-stream supports -ngl
      $argList += @('-ngl', $GpuLayers)
    }
    
    # Flash attention (custom builds only)
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

    # Quick health check
    if ($p.WaitForExit($StartupGraceMs)) {
      $stderrAll = try { $p.StandardError.ReadToEnd() } catch { '' }
      $stdoutAll = try { $p.StandardOutput.ReadToEnd() } catch { '' }
      Write-Host ("[whisper] exited quickly (code {0}) for Mic={1}" -f $p.ExitCode, $mic) -ForegroundColor Yellow
      if ($stderrAll) { Write-Host "[stderr][startup] $stderrAll" -ForegroundColor Red }
      if ($stdoutAll) { Write-Host "[stdout][startup] $stdoutAll" -ForegroundColor DarkYellow }
      continue
    }

    # Attach IO
    $stdout = $p.StandardOutput
    $stderr = $p.StandardError

    # Echo stderr (async, non-blocking)
    $stderrJob = Start-Job -ScriptBlock {
      param($stderrStream)
      try {
        while (-not $stderrStream.EndOfStream) {
          $line = $stderrStream.ReadLine()
          if ($line) { Write-Host "[stderr] $line" -ForegroundColor Red }
        }
      } catch {
        # Stream closed or error - exit gracefully
      }
    } -ArgumentList $stderr

    # Read loop with watchdog
    $lastOutputTime = Get-Date

    while (-not $p.HasExited) {
      # Non-blocking read with timeout
      $raw = $null
      if (-not $stdout.EndOfStream) {
        try {
          $raw = $stdout.ReadLine()
          if ($null -ne $raw) { $lastOutputTime = Get-Date }
        } catch {
          Write-Host "[whisper] ReadLine error: $_" -ForegroundColor Red
          break
        }
      }

      # Check for output timeout (watchdog)
      $silentSec = [int]((Get-Date) - $lastOutputTime).TotalSeconds
      if ($silentSec -ge $OutputTimeoutSec) {
        Write-Host "[whisper] WATCHDOG: No output for ${silentSec}s (threshold: ${OutputTimeoutSec}s) - killing process" -ForegroundColor Red
        try { $p.Kill() } catch {}
        break
      }

      if ($null -eq $raw) { Start-Sleep -Milliseconds 50; continue }
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
      
      # Adapt to whisper.cpp stream output
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
      
      if ($FlushOnPunct.IsPresent -and $buf.Length -ge 12 -and $buf -match '[\.!?]$') {
        Flush-Buf "punct"
      }
    }

    # Process ended - cleanup
    $exit = if ($p.HasExited) { $p.ExitCode } else { -1 }
    if ($buf.Trim()) { Flush-Buf "exit" }

    # Force kill if still running
    try {
      if (-not $p.HasExited) {
        Write-Host "[whisper] Force-killing hung process" -ForegroundColor Red
        $p.Kill()
        $p.WaitForExit(2000)  # Give it 2 seconds to die
      }
    } catch {}

    # Cleanup stderr job
    try {
      if ($stderrJob) {
        Stop-Job $stderrJob -Force -ErrorAction SilentlyContinue
        Remove-Job $stderrJob -Force -ErrorAction SilentlyContinue
      }
    } catch {}

    # Dispose streams
    try { $stdout.Close(); $stdout.Dispose() } catch {}
    try { $stderr.Close(); $stderr.Dispose() } catch {}
    try { $p.Dispose() } catch {}

    Write-Host ("[whisper] process exited (code {0}) Mic={1}" -f $exit, $mic) -ForegroundColor Yellow

    if ($NoRestart) { return }
    Write-Host ("[whisper] restarting in {0}s..." -f $RestartDelaySec) -ForegroundColor Yellow
    Start-Sleep -Seconds $RestartDelaySec
    $MicCandidates = @($mic)
  }

  if ($NoRestart) { break }
  Write-Host ("[whisper] retrying mic candidates after {0}s..." -f $RestartDelaySec) -ForegroundColor Yellow
  Start-Sleep -Seconds $RestartDelaySec
}
