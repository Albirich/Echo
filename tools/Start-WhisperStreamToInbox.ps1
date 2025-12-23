param(
  [string]$WhisperExe = "C:\ai\whisper\Release-cublas\stream.exe",
  [string]$Model      = "C:\ai\models\ggml-base.en.bin",
  [int]$MicIndex      = 1, # Hardcoded to OW810
  [string]$EchoHome   = $env:ECHO_HOME,
  [string]$UserName   = "user",
  [switch]$NoGPU,            
  [int]$Threads = 4,         
  [switch]$FlashAttn,        
  [switch]$NoRestart,        
  [int]$RestartDelaySec = 2,
  [int[]]$MicCandidates,
  
  # --- TUNING ---
  [int]$SilenceThresholdMs = 800,  # Wait 0.8s silence before sending final text
  [switch]$FlushOnPunct = $true,   # Send immediately if sentence ends with . ? !
  [double]$VoiceThresh = 0.6       # Hardware VAD: Ignore noise below 60%
)

if (-not $EchoHome) { $EchoHome = "D:\Echo" }
$Inbox = Join-Path $EchoHome "ui\inboxq"
New-Item -ItemType Directory -Force -Path $Inbox | Out-Null

# --- AUTO-DETECT ---
if (-not (Test-Path $Model)) {
    $Found = Get-ChildItem -Path (Join-Path $EchoHome "models") -Filter "ggml-*.bin" | Select-Object -First 1
    if ($Found) { $Model = $Found.FullName }
}
if (-not (Test-Path $WhisperExe)) { 
    $LocalExe = Join-Path $EchoHome "tools\whisper\stream.exe"
    if (Test-Path $LocalExe) { $WhisperExe = $LocalExe }
}

[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

# Technical Filters (Based on your logs)
$TechGarbage = @("[ Silence ]", "[Start speaking]", "[2K", "BLANK_AUDIO")

if (-not $MicCandidates) { $MicCandidates = @($MicIndex) }

Write-Host "--- ECHO EAR (Production VAD) ---" -ForegroundColor Cyan
Write-Host "Model: $(Split-Path $Model -Leaf)" -ForegroundColor Gray
Write-Host "Noise Gate: $VoiceThresh | Mic: $MicIndex" -ForegroundColor Gray

# Thread-safe buffer
$syncHash = [hashtable]::Synchronized(@{
    Buffer = ""
    LastDataTime = [DateTime]::Now
    HasData = $false
})

function Flush-Buf([string]$reason) {
    if (-not $syncHash.HasData) { return }
    
    $text = $syncHash.Buffer.Trim()
    
    # FILTER: Ignore tiny noise (< 2 chars)
    if ($text.Length -lt 2) { 
        $syncHash.Buffer = ""; $syncHash.HasData = $false; return 
    }
    
    # FILTER: Double check against garbage list
    foreach ($junk in $TechGarbage) {
        if ($text -like "*$junk*") {
             $syncHash.Buffer = ""; $syncHash.HasData = $false; return 
        }
    }

    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss-fff")
    $path = Join-Path $Inbox "$ts`_$UserName.txt"
    
    try {
        Set-Content -Path $path -Value $text -NoNewline -Encoding UTF8
        Write-Host ">> $text" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to write inbox file"
    }
    
    $syncHash.Buffer = ""
    $syncHash.HasData = $false
    $syncHash.LastDataTime = Get-Date 
}

while ($true) {
  foreach ($mic in $MicCandidates) {
    $p = New-Object System.Diagnostics.Process
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WhisperExe
    
    # ARGS: 
    # -vth : Hardware Noise Gate (Stops "Silence" spam)
    # --step 500 : Fast updates
    # --length 5000 : Short context to clear ghost words
    # NO -ngl (Your version crashes with it)
    $argList = @('-m', "`"$Model`"", '-c', $mic, '-t', $Threads, '--step', '500', '--length', '5000', '-vth', $VoiceThresh)
    if ($NoGPU) { $argList += '--no-gpu' }
    
    $psi.Arguments = ($argList -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true 
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p.StartInfo = $psi

    # --- ASYNC LISTENER (Prevents Freezing) ---
    $action = {
        if (-not $Event.SourceEventArgs.Data) { return }
        $line = $Event.SourceEventArgs.Data
        
        # Clean ANSI only
        $clean = $line -replace "[\u001B\u009B]\[[0-9;]*[a-zA-Z]", ""
        $clean = $clean.Trim()

        # Immediate Garbage Rejection
        if ($clean.Length -lt 1) { return }
        if ($clean.StartsWith("info:")) { return }
        if ($clean -match "\[\s*Silence\s*\]") { return }
        if ($clean -match "\[Start speaking\]") { return }

        # Lock buffer
        $h = $Event.MessageData
        $h.LastDataTime = [DateTime]::Now
        
        # DEBOUNCE LOGIC:
        # If new text starts with the old buffer, update it (e.g. "Hello" -> "Hello mate")
        if ($clean.StartsWith($h.Buffer)) {
             $h.Buffer = $clean
             $h.HasData = $true
        } 
        # If the buffer starts with the new text, ignore (it's a partial repeat)
        elseif ($h.Buffer.StartsWith($clean)) {
             # Do nothing, waiting for more context
        }
        # If it's totally new, append it
        else {
             if ($h.Buffer.Length -gt 0) { $h.Buffer += " " + $clean }
             else { $h.Buffer = $clean }
             $h.HasData = $true
        }
    }

    [void]$p.Start()
    Write-Host "Listening..." -ForegroundColor DarkGray
    
    $p.BeginOutputReadLine()
    $evt = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $action -MessageData $syncHash

    # --- WATCHDOG ---
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 100
        
        if ($syncHash.HasData) {
            $elapsed = (Get-Date) - $syncHash.LastDataTime
            
            # Flush if silence > 0.8s OR sentence ending punctuation found
            if ($elapsed.TotalMilliseconds -gt $SilenceThresholdMs) {
                Flush-Buf "timeout"
            }
            elseif ($FlushOnPunct -and ($syncHash.Buffer.Trim() -match '[.?!]$')) {
                Flush-Buf "punct"
            }
        }
    }

    Unregister-Event -SourceIdentifier $evt.Name
    try { $p.Kill() } catch {}
    if ($syncHash.HasData) { Flush-Buf "exit" }
    
    if ($NoRestart) { break }
    Start-Sleep -Seconds 1
  }
}