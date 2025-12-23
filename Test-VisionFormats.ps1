# Test different vision prompt formats for Qwen2.5-VL
param([string]$ImagePath)

if (-not $ImagePath) {
    $ImagePath = Get-ChildItem "d:\Echo\sense\screenshots\frame_*.png" -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

Write-Host "Testing with image: $ImagePath" -ForegroundColor Cyan

$bytes = [IO.File]::ReadAllBytes($ImagePath)
$b64 = [Convert]::ToBase64String($bytes)
Write-Host "Image size: $($bytes.Length) bytes`n" -ForegroundColor Gray

# Different prompt formats to test
$formats = @(
    @{
        Name = "Format 1: <|image_1|>"
        Prompt = "<|image_1|>`nWhat is shown in this image? Describe it in detail."
    },
    @{
        Name = "Format 2: <|vision_start|><|image_pad|><|vision_end|>"
        Prompt = "<|vision_start|><|image_pad|><|vision_end|>What is shown in this image? Describe it in detail."
    },
    @{
        Name = "Format 3: [IMG] token"
        Prompt = "[IMG]What is shown in this image? Describe it in detail."
    },
    @{
        Name = "Format 4: No special token"
        Prompt = "What is shown in this image? Describe it in detail."
    },
    @{
        Name = "Format 5: <image> tag"
        Prompt = "<image>What is shown in this image? Describe it in detail."
    },
    @{
        Name = "Format 6: Direct question"
        Prompt = "USER: Describe what you see.\nASSISTANT:"
    }
)

foreach ($format in $formats) {
    Write-Host "=== $($format.Name) ===" -ForegroundColor Yellow

    $body = @{
        prompt = $format.Prompt
        stream = $false
        image_data = @(@{ id = (Get-Random -Min 1000 -Max 999999); data = $b64 })
        n_predict = 80
        temperature = 0.1
        top_p = 0.9
    } | ConvertTo-Json -Depth 6

    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:8082/completion' `
            -Method Post `
            -ContentType 'application/json' `
            -Body $body `
            -UseBasicParsing `
            -TimeoutSec 60

        $result = ($resp.Content | ConvertFrom-Json)
        Write-Host "Response: " -ForegroundColor Green -NoNewline
        Write-Host $result.content.Substring(0, [Math]::Min(200, $result.content.Length))
        if ($result.content.Length -gt 200) { Write-Host "..." }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "`n=== Testing /v1/chat/completions endpoint ===" -ForegroundColor Cyan

$chatBody = @{
    model = "vision"
    messages = @(
        @{
            role = "user"
            content = @(
                @{
                    type = "image_url"
                    image_url = @{
                        url = "data:image/png;base64,$b64"
                    }
                },
                @{
                    type = "text"
                    text = "What do you see in this image? Describe it in detail."
                }
            )
        }
    )
    max_tokens = 150
    temperature = 0.1
} | ConvertTo-Json -Depth 10

try {
    $chatResp = Invoke-WebRequest -Uri 'http://127.0.0.1:8082/v1/chat/completions' `
        -Method Post `
        -ContentType 'application/json' `
        -Body $chatBody `
        -UseBasicParsing `
        -TimeoutSec 60

    Write-Host "Chat API Response:" -ForegroundColor Green
    Write-Host ($chatResp.Content | ConvertFrom-Json | ConvertTo-Json -Depth 8)
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        Write-Host $reader.ReadToEnd() -ForegroundColor Red
    }
}
