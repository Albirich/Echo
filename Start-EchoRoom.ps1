# Starts the Echo daemon (if not already running) and launches the Electron UI
# Uses cmd.exe so npm runs as a batch, avoiding the "open in Notepad" issue.

$ErrorActionPreference = 'SilentlyContinue'
# hard-set Ollama base URL for all children
$env:OLLAMA_HOST = "http://127.0.0.1:11434"

# Resolve ECHO_HOME
$ECHO_HOME = $env:ECHO_HOME
if (-not $ECHO_HOME -or $ECHO_HOME.Trim().Length -eq 0) { $ECHO_HOME = 'D:\\Echo' }
[Environment]::SetEnvironmentVariable('ECHO_HOME', $ECHO_HOME, 'Process') | Out-Null

$daemonPs1 = Join-Path $ECHO_HOME 'Start-Echo.ps1'
$uiDir     = Join-Path $ECHO_HOME 'room\\echo-room'
$outbox    = Join-Path $ECHO_HOME 'ui\\outbox.jsonl'
$inboxq    = Join-Path $ECHO_HOME 'ui\\inboxq'

# Ensure minimal folders/files
New-Item -ItemType Directory -Force -Path $uiDir,$inboxq | Out-Null
if (-not (Test-Path $outbox)) { [System.IO.File]::WriteAllText($outbox, '', (New-Object System.Text.UTF8Encoding($false))) }

# Find npm.cmd (prefer explicit .cmd over bare "npm")
$npmCmd = $null
try { $npmCmd = (Get-Command 'npm.cmd' -ErrorAction SilentlyContinue).Source } catch { }
if (-not $npmCmd) {
  $cand = Join-Path $env:ProgramFiles 'nodejs\\npm.cmd'
  if (Test-Path $cand) { $npmCmd = $cand }
}
$haveNpm = ($npmCmd -and (Test-Path $npmCmd))

# 1) Start daemon if not already running (hidden, no extra window)
$daemonRunning = $false
try {
  $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'"
  foreach ($p in $procs) {
    if ($p.CommandLine -and $p.CommandLine -match [regex]::Escape($daemonPs1)) { $daemonRunning = $true; break }
  }
} catch { }

if (-not $daemonRunning) {
  Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $daemonPs1)
}

# 2) First-run deps: npm install (via cmd.exe so .cmd runs correctly)
if ($haveNpm -and -not (Test-Path (Join-Path $uiDir 'node_modules\\electron'))) {
  $args = '/c ""' + $npmCmd + '" install"'
  Start-Process -WindowStyle Minimized -FilePath $env:ComSpec -ArgumentList $args -WorkingDirectory $uiDir -Wait
}

# 3) Launch UI (prefer hidden console)
if ($haveNpm) {
  $args = '/c ""' + $npmCmd + '" start"'
  Start-Process -WindowStyle Hidden -FilePath $env:ComSpec -ArgumentList $args -WorkingDirectory $uiDir
} else {
  # Fallback: try npx.cmd electron .
  $npxCmd = $null
  try { $npxCmd = (Get-Command 'npx.cmd' -ErrorAction SilentlyContinue).Source } catch { }
  if ($npxCmd -and (Test-Path $npxCmd)) {
    $args = '/c ""' + $npxCmd + '" electron ."'
    Start-Process -WindowStyle Hidden -FilePath $env:ComSpec -ArgumentList $args -WorkingDirectory $uiDir
  } else {
    Write-Host 'Could not find npm/npx. Install Node.js from https://nodejs.org/ and try again.'
  }
}
