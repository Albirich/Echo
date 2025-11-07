#requires -Version 5.1
param(
  [ValidateSet('Chat','IM')] [string]$Role = 'Chat',
  [Parameter(Mandatory=$true)] [string]$ModelPath,

  # inference params
  [int]$CtxSize   = 2048,
  [int]$NPredict  = 192,
  [int]$Threads   = 1,
  [int]$GpuLayers = 100,    # 24 for 2B; 100 = as many as possible
  [int]$Batch     = 512,
  [int]$UBatch    = 0,      # only used if llama-cli -h shows -ub/--ubatch-size

  [string]$EchoHome = 'D:\Echo'
)

$ErrorActionPreference = 'Stop'
$exe = 'D:\llama-cpp\llama-cli.exe'

if (-not (Test-Path -LiteralPath $exe))       { throw "llama-cli.exe not found at $exe" }
if (-not (Test-Path -LiteralPath $ModelPath)) { throw "Model not found: $ModelPath" }

# Optional env overrides for GPU layers
try {
  if ($env:ECHO_LLAMA_GPU_LAYERS -and $env:ECHO_LLAMA_GPU_LAYERS.Trim()) {
    $GpuLayers = [int]$env:ECHO_LLAMA_GPU_LAYERS
  } elseif ($Role -eq 'IM' -and $env:ECHO_IM_GPU_LAYERS -and $env:ECHO_IM_GPU_LAYERS.Trim()) {
    $GpuLayers = [int]$env:ECHO_IM_GPU_LAYERS
  }
} catch {}

# Optional env overrides for threads
try {
  if ($Role -eq 'IM' -and $env:ECHO_IM_THREADS -and $env:ECHO_IM_THREADS.Trim()) {
    $Threads = [int]$env:ECHO_IM_THREADS
  } elseif ($env:ECHO_LLAMA_THREADS -and $env:ECHO_LLAMA_THREADS.Trim()) {
    $Threads = [int]$env:ECHO_LLAMA_THREADS
  }
} catch {}

# --- folders / setup ---
function Ensure-Dir([string]$p){
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
$stateDir = Join-Path $EchoHome 'state'
$busRole  = Join-Path (Join-Path $EchoHome 'bus') $Role
$inDir    = Join-Path $busRole 'in'
$outDir   = Join-Path $busRole 'out'
$logDir   = Join-Path $EchoHome 'logs'
$tmpDir   = Join-Path $EchoHome 'tmp'
Ensure-Dir $stateDir; Ensure-Dir $inDir; Ensure-Dir $outDir; Ensure-Dir $logDir; Ensure-Dir $tmpDir

$pidFile = Join-Path $stateDir ("resident.{0}.pid" -f $Role)
Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII

Write-Host ("[{0}] Resident runner ready. IN: {1} | OUT: {2}" -f $Role,$inDir,$outDir)

# --- helpers ---
function Invoke-Proc([string[]]$argList){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $exe
  $psi.Arguments              = ($argList -join ' ')
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $ok = $p.WaitForExit(60000)  # 60s hard cap
  if (-not $ok) { try { $p.Kill() } catch {} ; Start-Sleep -Milliseconds 100 }
  @{ out = $p.StandardOutput.ReadToEnd(); err = $p.StandardError.ReadToEnd() }
}

# --- per-job: try non-interactive; if empty, fall back to interactive streaming ---
function Run-One([string]$inFile,[string]$outFile){
  # Read the job and wrap if it's plain text (no chat markers)
  $raw = [System.IO.File]::ReadAllText($inFile,[Text.UTF8Encoding]::new($false))
  $feedFile = $inFile
  $composed = $null
  if ($raw -notmatch '<start_of_turn>|<\|im_start\|>') {
    $composed = Join-Path $tmpDir ("chat.{0}.{1}.txt" -f [IO.Path]::GetFileNameWithoutExtension($inFile),(Get-Random))
    @"
<start_of_turn>user
$raw
<end_of_turn>
<start_of_turn>model
"@ | Set-Content -LiteralPath $composed -NoNewline -Encoding UTF8
    $feedFile = $composed
  }

  # Build interactive args
  $args = @(
    '-m',   $ModelPath,
    '-i',
    '-c',   $CtxSize,
    '-n',   $NPredict,
    '-t',   $Threads,
    '-ngl', $GpuLayers,
    '-b',   $Batch,
    '-f',   $feedFile,
    '-r',   '<end_of_turn>'
  )
  if ($UBatch -gt 0) { $args += @('-ub', $UBatch) }

  # Start process
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $exe
  $psi.Arguments              = ($args -join ' ')
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  # Open OUT with shared access so readers/AV don't block us
  $fs = [System.IO.File]::Open(
    $outFile,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::ReadWrite
  )
  $writer = New-Object System.IO.StreamWriter($fs, [Text.UTF8Encoding]::new($false))
  $writer.AutoFlush = $false

  $reader = $p.StandardOutput
  $buf    = New-Object char[] 4096
  $acc    = New-Object System.Text.StringBuilder
  $flushT = [System.Diagnostics.Stopwatch]::StartNew()
  $idleT  = [System.Diagnostics.Stopwatch]::StartNew()
  $hardT  = [System.Diagnostics.Stopwatch]::StartNew()

  $IdleMs  = 2000
  $HardSec = 60

  try {
    while ($true) {
      if ($p.HasExited) { break }
      $n = $reader.Read($buf, 0, $buf.Length)   # blocking
      if ($n -le 0) {
        if ($acc.Length -gt 0 -and $idleT.ElapsedMilliseconds -ge $IdleMs) { break }
        continue
      }
      $chunk = -join $buf[0..($n-1)]
      $idleT.Restart()

      $writer.Write($chunk)
      $acc.Append($chunk) | Out-Null

      if ($flushT.ElapsedMilliseconds -ge 100) { $writer.Flush(); $flushT.Restart() }

      $txt = $acc.ToString()
      if ($txt.IndexOf('<end_of_turn>', [StringComparison]::Ordinal) -ge 0) { break }
      if ($hardT.Elapsed.TotalSeconds -ge $HardSec) { break }
    }
  }
  finally {
    try { $writer.Flush() } catch {}
    try { $writer.Close(); $fs.Dispose() } catch {}
  }

  # Log stderr (so you see banner/errors)
  try {
    $stdErr = $p.StandardError.ReadToEnd()
    if ($stdErr -and $stdErr.Trim().Length -gt 0) {
      Add-Content -LiteralPath (Join-Path $logDir ("resident.{0}.err.log" -f $Role)) -Value $stdErr
    }
  } catch {}

  try { if (-not $p.HasExited) { $p.Kill() } } catch {}

  if ($composed) { try { Remove-Item -LiteralPath $composed -Force } catch {} }
}

# --- main poll loop (copy inbox -> temp to avoid races) ---
try{
  while($true){
    $job = Get-ChildItem -LiteralPath $inDir -Filter *.txt -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime | Select-Object -First 1
    if (-not $job){ Start-Sleep -Milliseconds 200; continue }

    $inFile   = $job.FullName
    $outFile  = Join-Path $outDir $job.Name
    $tmpIn    = Join-Path $tmpDir ("{0}.{1}.txt" -f $job.BaseName, (Get-Random))

    # private copy for llama-cli so nothing else can lock/delete it mid-run
    [System.IO.File]::Copy($inFile, $tmpIn, $true)

    Write-Host ("[{0}] job picked: {1}" -f $Role,$job.Name)
    try{
      Run-One -inFile $tmpIn -outFile $outFile
      Write-Host ("[{0}] wrote: {1}" -f $Role,$outFile)
    } catch {
      $msg = "[{0}] error: {1}" -f $Role,$_.Exception.Message
      Add-Content -LiteralPath (Join-Path $logDir ("resident.{0}.err.log" -f $Role)) -Value $msg
      if (-not (Test-Path -LiteralPath $outFile)) {
        [System.IO.File]::WriteAllText($outFile,"",[Text.UTF8Encoding]::new($false))
      }
      Write-Host $msg
    } finally {
      try { Remove-Item -LiteralPath $inFile -Force } catch {}
      try { Remove-Item -LiteralPath $tmpIn  -Force } catch {}
    }
  }
} finally {
  try{ Remove-Item -LiteralPath $pidFile -Force }catch{}
}
