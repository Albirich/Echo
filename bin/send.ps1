param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$Text
)

$ErrorActionPreference = 'Stop'

# Resolve Echo home (use ECHO_HOME if set; else parent of this script's folder)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$echoHome  = if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { $env:ECHO_HOME.Trim() } else { Resolve-Path (Join-Path $scriptDir '..') }

# Inbox queue path
$inboxQ = Join-Path $echoHome 'ui\inboxq'
if (-not (Test-Path $inboxQ)) { New-Item -ItemType Directory -Path $inboxQ -Force | Out-Null }

# Unique message file
$ts  = Get-Date -Format 'yyyyMMdd_HHmmssfff'
$id  = [Guid]::NewGuid().ToString('N')
$fn  = "{0}-{1}.txt" -f $ts, $id
$path = Join-Path $inboxQ $fn

# Write the message as plain UTF-8 text (what the chat daemon expects)
[System.IO.File]::WriteAllText($path, $Text, [System.Text.Encoding]::UTF8)

Write-Host "[send] Dropped message into inbox:" -ForegroundColor Green
Write-Host "       $path"
