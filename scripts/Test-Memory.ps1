$ErrorActionPreference = 'Stop'

if (-not $env:ECHO_HOME -or -not (Test-Path $env:ECHO_HOME)) {
  $env:ECHO_HOME = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

Import-Module (Join-Path $env:ECHO_HOME 'scripts\Memory.psm1') -Force

Write-Host "--- memory.search: #secret_code ---"
$res = Search-DeepMemory -Query '#secret_code' -Limit 3 -IncludeContent
$res | Format-Table id,ts,source,score -AutoSize

if ($res -and $res.Count -gt 0) {
  Write-Host "`n--- memory.read: first id ---"
  $full = Get-DeepMemoryById -Id $res[0].id
  $full | Format-List
}

