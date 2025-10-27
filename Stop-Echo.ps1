# Stop-Echo.ps1  — PowerShell 5.1-safe
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'SilentlyContinue'
$here   = Split-Path -LiteralPath $PSCommandPath
$state  = Join-Path $here 'state'
$logs   = Join-Path $here 'logs'

function Kill-PidsFromFiles($files) {
  foreach ($f in $files) {
    if (Test-Path -LiteralPath $f) {
      Get-Content -LiteralPath $f | ForEach-Object {
        if ($_ -match '^\d+$') { Stop-Process -Id [int]$_ -Force:$Force -ErrorAction SilentlyContinue }
      }
      Remove-Item -LiteralPath $f -Force
    }
  }
}

Write-Verbose "[StopEcho] Killing known child processes (from PID files)..."
$pidFiles = @(
  Join-Path $state 'ollama.pid'),
  (Join-Path $state 'chat.pid'),
  (Join-Path $state 'im.pid'),
  (Join-Path $state 'vision.pid'),
  (Join-Path $state 'visionprobe.pid'),
  (Join-Path $state 'room.pid')
Kill-PidsFromFiles $pidFiles

Write-Verbose "[StopEcho] Killing common stragglers by name..."
# llama.cpp + Ollama + helpers
Get-Process -Name 'llama-cli','llama-mtmd-cli','ollama','ollama.exe','ollama_rocm' `
  | Stop-Process -Force:$Force
# whisper stream variants (whisper.cpp stream.exe or custom whisper-stream.exe)
Get-Process -Name 'stream','stream.exe','whisper-stream','whisper-stream.exe' -ErrorAction SilentlyContinue `
  | Stop-Process -Force:$Force
# any powershells that were launched to run the sub-scripts directly
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" `
  | Where-Object { $_.CommandLine -match 'Start-(EchoAll|Echo|IM|Echoroom|VisionProbe|WhisperStreamToInbox).*\.ps1' } `
  | ForEach-Object { Stop-Process -Id $_.ProcessId -Force:$Force }

Write-Verbose "[StopEcho] Ensuring Start-IM is terminated..."
# Explicitly stop any shells running Start-IM (covers alternate invocations)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" `
  | Where-Object { $_.CommandLine -match '(?i)Start-IM(\.ps1)?(\s|"|$)' } `
  | ForEach-Object { Stop-Process -Id $_.ProcessId -Force:$Force }

# If a visible console was used to run Start-IM directly, close it by title
Get-Process | Where-Object { $_.MainWindowTitle -match '(?i)Start-IM' } `
  | ForEach-Object { Stop-Process -Id $_.Id -Force:$Force }

Write-Verbose "[StopEcho] Closing launcher window (“Echo Room (Start)”)..."
# 1) by exact window title
Get-Process | Where-Object { $_.MainWindowTitle -like 'Echo Room (Start)*' } `
  | ForEach-Object { Stop-Process -Id $_.Id -Force:$Force }

# 2) by command line containing Start-EchoAll.ps1 (covers renamed windows)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" `
  | Where-Object { $_.CommandLine -match 'Start-EchoAll\.ps1' } `
  | ForEach-Object { Stop-Process -Id $_.ProcessId -Force:$Force }

# 3) last-ditch: kill consoles that still have our banner
Get-Process | Where-Object {
  $_.MainWindowTitle -match 'Echo minimal stack launched|EchoAll'
} | Stop-Process -Force:$Force

Write-Verbose "[StopEcho] Closing Echo Room (Electron) UI..."
# Kill Electron window by title (title set in renderer/index.html)
Get-Process | Where-Object { $_.MainWindowTitle -like 'Echo Room*' } `
  | ForEach-Object { Stop-Process -Id $_.Id -Force:$Force }

# Kill electron.exe spawned from room/echo-room (match by command line)
Get-CimInstance Win32_Process -Filter "Name='electron.exe' OR Name='electron'" `
  | Where-Object { $_.CommandLine -match '(?i)room\\echo-room' -or $_.CommandLine -match '(?i)electron\s+\.' } `
  | ForEach-Object { Stop-Process -Id $_.ProcessId -Force:$Force }

# Kill helper shells for npm/npx that launched echo-room
Get-CimInstance Win32_Process -Filter "Name='cmd.exe' OR Name='npm.exe' OR Name='npx.exe' OR Name='node.exe'" `
  | Where-Object { $_.CommandLine -match '(?i)room\\echo-room' -or $_.CommandLine -match '(?i)npm(\.cmd)?\s+start' -or $_.CommandLine -match '(?i)npx(\.cmd)?\s+electron\s+\.' } `
  | ForEach-Object { Stop-Process -Id $_.ProcessId -Force:$Force }

Write-Host "[StopEcho] All Echo processes requested to stop. Close any leftover shells if they persist."
