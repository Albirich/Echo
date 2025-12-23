# ECHO VOICE MODULE - WATCHER MODE (NeuTTS Air)
# loops and processes .txt files from inbox

# --- CONFIGURATION ---
$LlamaTTS     = "D:\llama-cpp\llama-tts.exe" 
# Ensure this matches your downloaded filename
$Model        = "D:\Echo\Models\neutss-air-BF16.gguf" 
# IMPORTANT: NeuTTS needs its own codec. If you don't have a neucodec.gguf, 
# try commenting this line out, but quality may suffer or fail.
$Vocoder      = "D:\Echo\Models\neucodec.gguf" 

$InboxDir     = "D:\Echo\ui\inbox_voice"
$ProcessedDir = "D:\Echo\ui\processed_voice"
$AudioDir     = "D:\Echo\VoiceOutput"
$RefAudio     = "D:\Echo\config\reference_voice.wav"

# --- SETUP ---
Write-Host "--- ECHO VOICE ENGINE STARTING ---" -ForegroundColor Cyan

# Create directories if missing
if (!(Test-Path $ProcessedDir)) { New-Item -ItemType Directory -Path $ProcessedDir | Out-Null }
if (!(Test-Path $InboxDir)) { New-Item -ItemType Directory -Path $InboxDir | Out-Null }

# GPU Check
$dll = "D:\llama-cpp\ggml-cuda.dll"
if (Test-Path $dll) {
    Write-Host "GPU Engine Found: OK" -ForegroundColor Green
} else {
    Write-Host "WARNING: Running on CPU. Latency will be high." -ForegroundColor Red
}

Write-Host "Waiting for incoming voice messages in: $InboxDir" -ForegroundColor Yellow

# --- MAIN LOOP ---
while ($true) {
    # Check for .txt files
    $txtFiles = Get-ChildItem -Path $InboxDir -Filter "*.txt"
    
    foreach ($file in $txtFiles) {
        $text = Get-Content -Path $file.FullName -Raw
        Write-Host "Processing: $($file.Name)..." -ForegroundColor Cyan

        # Define Arguments
        # NeuTTS Air uses the reference audio to "clone" the voice style on the fly.
        $argsList = @(
            "--model", $Model,
            "--output", "$AudioDir\echo_out.wav",
            "--n-gpu-layers", "99",       # Offload all layers to GPU
            "--prompt", $text
        )

        # Add Vocoder if present
        if (Test-Path $Vocoder) {
            $argsList += "--model-vocoder"
            $argsList += $Vocoder
        }

        # Add Reference Audio (Voice Cloning)
        if (Test-Path $RefAudio) {
            $argsList += "--tts-speaker-file"
            $argsList += $RefAudio
            # Optional: If you have the text of what the reference audio says, 
            # adding "--tts-speaker-text" "actual text here" improves quality massively.
        }

        # Run Generation
        $StartTime = Get-Date
        & $LlamaTTS $argsList | Out-Null
        $EndTime = Get-Date
        
        # Check Result
        if (Test-Path "$AudioDir\echo_out.wav") {
            $Duration = ($EndTime - $StartTime).TotalSeconds
            Write-Host "Generated in $Duration seconds." -ForegroundColor Green
            
            # Play Audio
            $player = New-Object System.Media.SoundPlayer("$AudioDir\echo_out.wav")
            $player.PlaySync()
            $player.Dispose() # Release file lock

            # Move text file to processed so we don't repeat it
            Move-Item -Path $file.FullName -Destination "$ProcessedDir\$($file.Name)" -Force
        } else {
            Write-Host "ERROR: Generation failed." -ForegroundColor Red
        }
    }

    # Sleep briefly to save CPU usage
    Start-Sleep -Milliseconds 500
}