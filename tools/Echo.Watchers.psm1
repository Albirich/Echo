function Start-QueueWatcher {
[CmdletBinding()]
param(
[Parameter(Mandatory)] [string]$Path,
[string]$Filter = '*.jsonl',
[switch]$Recurse,
[Parameter(Mandatory)] [scriptblock]$OnFile
)


if (-not (Test-Path -LiteralPath $Path)) {
New-Item -ItemType Directory -Path $Path | Out-Null
}


$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $Path
$fsw.Filter = $Filter
$fsw.IncludeSubdirectories = [bool]$Recurse
$fsw.EnableRaisingEvents = $true


$handled = New-Object System.Collections.Concurrent.ConcurrentDictionary[string,datetime]


$action = {
param($sender, $e)
$OnFileRef = $ExecutionContext.SessionState.PSVariable.Get('OnFileRef').Value
$HandledRef = $ExecutionContext.SessionState.PSVariable.Get('HandledRef').Value
try {
$now = Get-Date
$key = $e.FullPath.ToLowerInvariant()
$last = $HandledRef[$key]
if ($last -and ($now - $last).TotalMilliseconds -lt 50) { return }
$HandledRef[$key] = $now


for ($i=0; $i -lt 20; $i++) {
try { $s = [IO.File]::Open($e.FullPath, 'Open', 'Read', 'ReadWrite'); $s.Close(); break }
catch { Start-Sleep -Milliseconds 10 }
}


& $OnFileRef $e.FullPath
} catch {
Write-Warning ("Watcher error: {0}" -f $_.Exception.Message)
}
}


Set-Variable -Name OnFileRef -Value $OnFile -Scope Script
Set-Variable -Name HandledRef -Value $handled -Scope Script


$created = Register-ObjectEvent -InputObject $fsw -EventName Created -Action $action
$changed = Register-ObjectEvent -InputObject $fsw -EventName Changed -Action $action


Write-Host "Watching $Path ($Filter) ..." -ForegroundColor DarkGray
return [PSCustomObject]@{
Watcher = $fsw
Subscriptions = @($created, $changed)
Stop = {
$fsw.EnableRaisingEvents = $false
$created | Unregister-Event; $changed | Unregister-Event
$fsw.Dispose()
}
}
}


Export-ModuleMember -Function Start-QueueWatcher