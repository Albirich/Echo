<#
  Stop-Echo.ps1 – Kill all Echo-related processes (chat, IM, UI, vision, llama daemon/cli)
  Safe defaults: stop llama.cpp components automatically; ask before killing Ollama.
#>

param(
  [switch]$YesToAll
)

Write-Host "Stopping Echo stack..." -ForegroundColor Cyan

# Helper to stop a list of process objects safely
function Stop-Procs($procs, [string]$Label) {
  foreach ($p in $procs) {
    try {
      Write-Host ("Killing {0} - {1}" -f $p.ProcessId, $Label) -ForegroundColor Yellow
      Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    } catch { }
  }
}

# 1) Kill PowerShell processes running Echo scripts (PS 5.1 safe via WMI)
$scriptMatches = @(
  'Start-Echo.ps1',
  'Start-IM.ps1',
  'Start-EchoAll.ps1',
  'Start-VisionProbe-Burst.ps1',
  'LlamaChatDaemon.ps1',
  'Start-LocalLLM.ps1'
)
foreach ($pat in $scriptMatches) {
  $ps = Get-WmiObject Win32_Process -Filter "name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like ("*{0}*" -f $pat) }
  Stop-Procs $ps "PowerShell:$pat"
}

# 2) Kill llama.cpp processes (daemon runs llama-cli per request)
$llamaCli = Get-WmiObject Win32_Process -Filter "name='llama-cli.exe'"
Stop-Procs $llamaCli "llama-cli.exe"

# (Optional) kill llama-server if running
$llamaSrv = Get-WmiObject Win32_Process -Filter "name='llama-server.exe'"
Stop-Procs $llamaSrv "llama-server.exe"

# 3) Kill Electron UI (if any) – keep narrow to Electron titled Echo
$electron = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'electron' -and $_.MainWindowTitle -like '*Echo*' }
foreach ($p in $electron) {
  try {
    Write-Host ("Killing {0} - Electron UI" -f $p.Id) -ForegroundColor Yellow
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  } catch { }
}

Write-Host "`nEcho stack stopped." -ForegroundColor Green
