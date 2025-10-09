# Stop-Echo.ps1 - Kill all Echo processes

Write-Host "Stopping Echo stack..." -ForegroundColor Cyan

# Kill PowerShell processes running Echo scripts
$echoScripts = @('Start-Echo', 'Start-IM', 'Start-VisionProbe')
foreach ($script in $echoScripts) {
    Get-WmiObject Win32_Process -Filter "name='powershell.exe'" | Where-Object {
        $_.CommandLine -like "*$script*"
    } | ForEach-Object {
        Write-Host "Killing $($_.ProcessId) - $script" -ForegroundColor Yellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Kill Electron UI
Get-Process | Where-Object {
    $_.ProcessName -eq 'electron' -and $_.MainWindowTitle -like '*Echo*'
} | ForEach-Object {
    Write-Host "Killing $($_.Id) - Electron UI" -ForegroundColor Yellow
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

# Optional: Kill Ollama if it was started by Echo
$killOllama = Read-Host "Kill Ollama server? (y/n)"
if ($killOllama -eq 'y') {
    Get-Process | Where-Object { $_.ProcessName -eq 'ollama' } | ForEach-Object {
        Write-Host "Killing $($_.Id) - Ollama" -ForegroundColor Yellow
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nEcho stack stopped." -ForegroundColor Green
