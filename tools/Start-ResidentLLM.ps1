param(
  [ValidateSet('Chat','IM')] [string]$Role = 'Chat',
  [string]$ModelPath = 'D:\Echo\models\athirdpath-7b-Q4_K_M.gguf',
  [int]$CtxSize = 2048,
  [int]$NPredict = 256,

  # leave these nullable; we’ll fill them from env or fallback below
  [Nullable[Int]]$Threads,
  [Nullable[Int]]$GpuLayers,
  [Nullable[Int]]$Batch,
  [Nullable[Int]]$UBatch,

  [string]$EchoHome = 'D:\Echo',
  [int]$ReadBuf = 4096
)
function Get-EnvInt {
  param([string]$Name, [int]$Default)
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ($v -and ($v -match '^\d+$')) { return [int]$v }
  return $Default
}

if (-not $PSBoundParameters.ContainsKey('Threads'))    { $Threads    = Get-EnvInt 'ECHO_LLAMA_THREADS' 6 }
if (-not $PSBoundParameters.ContainsKey('GpuLayers'))  { $GpuLayers  = Get-EnvInt 'ECHO_LLAMA_GPU' 35 }
if (-not $PSBoundParameters.ContainsKey('Batch'))      { $Batch      = Get-EnvInt 'ECHO_LLAMA_BATCH' 512 }
if (-not $PSBoundParameters.ContainsKey('UBatch'))     { $UBatch     = Get-EnvInt 'ECHO_LLAMA_UBATCH' 128 }

$ErrorActionPreference = 'Stop'
$exe = "D:\llama-cpp\llama-cli.exe"  # adjust if different
$bus = Join-Path $EchoHome "bus\$Role"
$state = Join-Path $EchoHome "state"
$null = New-Item -ItemType Directory -Force -Path $bus,$state | Out-Null

# Use a constant sentinel; we instruct the model to print it at the end.
$SENTINEL = '<<<EOT>>>'
$PIDFILE  = Join-Path $state "resident.$Role.pid"
Set-Content -Path $PIDFILE -Value $PID

# Launch llama-cli in interactive mode with clean I/O (no banners)
$argList = @(
  '-m', $ModelPath,
  '--ctx-size', $CtxSize,
  '--n-predict', $NPredict,
  '--threads', $Threads,
  '--n-gpu-layers', $GpuLayers,
  '--batch-size', $Batch,
  '--ubatch-size', $UBatch,
  '--interactive',
  '--instruct',
  '--simple-io'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = ($argList -join ' ')
$psi.UseShellExecute = $false
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow = $true

$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()

# Utility: write a prompt and stream output until SENTINEL appears
function Invoke-One {
  param([string]$prompt, [string]$outFile)

  # Force the model to mark completion reliably
  $full = @"
$prompt

When you are completely finished, output exactly $SENTINEL and nothing else after it.
"@

  $p.StandardInput.WriteLine($full)

  $buf = New-Object System.Text.StringBuilder
  $fs  = [System.IO.StreamWriter]::new($outFile, $false, [Text.UTF8Encoding]::new($false))

  try {
    while ($true) {
      $ch = $p.StandardOutput.Read()  # -1 if closed
      if ($ch -lt 0) { throw "llama-cli exited unexpectedly." }
      $c = [char]$ch
      $fs.Write($c)        # live stream to file
      $buf.Append($c) | Out-Null

      if ($buf.Length -ge $SENTINEL.Length) {
        $tail = $buf.ToString($buf.Length - $SENTINEL.Length, $SENTINEL.Length)
        if ($tail -eq $SENTINEL) { break }
      }
    }
  }
  finally {
    $fs.Flush(); $fs.Close()
  }

  # Strip sentinel from the output file
  $txt = (Get-Content $outFile -Raw).Replace($SENTINEL,'')
  Set-Content -Path $outFile -Value $txt -NoNewline
}

# Main loop: watch queue and process requests
$reqDir = Join-Path $bus 'in'
$outDir = Join-Path $bus 'out'
$null = New-Item -ItemType Directory -Force -Path $reqDir,$outDir | Out-Null

Write-Host "[$Role] Resident LLM ready. Queue: $reqDir"
while (-not $p.HasExited) {
  $jobs = Get-ChildItem -Path $reqDir -Filter '*.txt' -File | Sort-Object LastWriteTime
  if ($jobs.Count -eq 0) { Start-Sleep -Milliseconds 80; continue }

  foreach ($job in $jobs) {
    $id  = [IO.Path]::GetFileNameWithoutExtension($job.Name)
    $out = Join-Path $outDir "$id.txt"
    $prompt = Get-Content $job.FullName -Raw

    try {
      Invoke-One -prompt $prompt -outFile $out
    } catch {
      Set-Content $out "[RESIDENT-ERROR] $($_.Exception.Message)`n"
    } finally {
      Remove-Item $job.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}

throw "Resident $Role worker terminated."
