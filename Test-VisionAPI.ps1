# Test Vision API to diagnose image processing issue
param([string]$ImagePath)

if (-not $ImagePath) {
    # Use the most recent screenshot
    $ImagePath = Get-ChildItem "d:\Echo\sense\screenshots\frame_*.png" -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

Write-Host "Testing with image: $ImagePath" -ForegroundColor Cyan

if (-not (Test-Path $ImagePath)) {
    Write-Host "ERROR: Image not found" -ForegroundColor Red
    exit 1
}

# Encode image
$bytes = [IO.File]::ReadAllBytes($ImagePath)
$b64 = [Convert]::ToBase64String($bytes)
Write-Host "Image size: $($bytes.Length) bytes, base64 length: $($b64.Length)" -ForegroundColor Gray

# Test 1: /completion endpoint with current format
Write-Host "`n=== Test 1: /completion with <|image_1|> ===" -ForegroundColor Yellow

$body1 = @{
    prompt = "<|image_1|>`nWhat do you see in this image?"
    stream = $false
    image_data = @(@{ id = 12345; data = $b64 })
    cache_prompt = $false
    n_predict = 100
    temperature = 0.1
} | ConvertTo-Json -Depth 6

try {
    $resp1 = Invoke-WebRequest -Uri 'http://127.0.0.1:8082/completion' `
        -Method Post `
        -ContentType 'application/json' `
        -Body $body1 `
        -UseBasicParsing `
        -TimeoutSec 120
    Write-Host "Response:" -ForegroundColor Green
    Write-Host ($resp1.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5)
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 2: Try without image token
Write-Host "`n=== Test 2: /completion without image token ===" -ForegroundColor Yellow

$body2 = @{
    prompt = "Describe this image in detail."
    stream = $false
    image_data = @(@{ id = 67890; data = $b64 })
    cache_prompt = $false
    n_predict = 100
    temperature = 0.1
} | ConvertTo-Json -Depth 6

try {
    $resp2 = Invoke-WebRequest -Uri 'http://127.0.0.1:8082/completion' `
        -Method Post `
        -ContentType 'application/json' `
        -Body $body2 `
        -UseBasicParsing `
        -TimeoutSec 120
    Write-Host "Response:" -ForegroundColor Green
    Write-Host ($resp2.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5)
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 3: Check server health
Write-Host "`n=== Test 3: Server health ===" -ForegroundColor Yellow
try {
    $health = Invoke-WebRequest -Uri 'http://127.0.0.1:8082/health' -UseBasicParsing
    Write-Host "Server health: $($health.Content)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 4: Get server props
Write-Host "`n=== Test 4: Server props ===" -ForegroundColor Yellow
try {
    $props = Invoke-WebRequest -Uri 'http://127.0.0.1:8082/props' -UseBasicParsing
    Write-Host ($props.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5)
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
