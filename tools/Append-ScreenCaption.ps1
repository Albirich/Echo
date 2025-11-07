param(
  [string]$Latest = "$(Split-Path -Parent $PSCommandPath)\..\ui\screen.caption.json",
  [string]$Jsonl  = "$(Split-Path -Parent $PSCommandPath)\..\ui\screen.captions.jsonl",
  [int]$Retain    = 200
)

$ErrorActionPreference = 'Stop'

function Ensure-Dir([string]$p) {
  $d = Split-Path -Parent $p
  if ($d -and -not (Test-Path -LiteralPath $d)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }
}

Ensure-Dir $Jsonl

if (-not (Test-Path -LiteralPath $Latest)) { return } # nothing to do yet

# Load the current single-caption json (VisionProbe writes this)
try {
  $cap = Get-Content -LiteralPath $Latest -Raw | ConvertFrom-Json
} catch { return }

# Safely pull fields (guard nulls)
$ts    = $cap.ts
$title = ""
try { $title = ($cap.active_window.title | Out-String).Trim() } catch { }

$frames = 0
try { if ($cap.burst -and $cap.burst.frame_count) { $frames = [int]$cap.burst.frame_count } } catch { }

$last = ""
try { if ($cap.burst -and $cap.burst.last_frame) { $last = $cap.burst.last_frame } } catch { }

# Build summary (prefer provided, else synthesize from visible_text/title)
$summary = $cap.summary
if (-not $summary -or ($summary -is [array] -and $summary.Count -eq 0)) {
  $vt = ""
  try {
    if ($cap.visible_text -is [array] -and $cap.visible_text.Count -gt 0) {
      $vt = ($cap.visible_text | Where-Object { $_ -and $_.ToString().Trim().Length -gt 0 } | Select-Object -First 3) -join " | "
    }
  } catch { }

  $synth = $title
  if ($vt) { $synth = $synth + " — " + $vt }
  $summary = $synth.Trim()
  if (-not $summary -or $summary.Trim().Length -eq 0) { $summary = "(no summary)" }
}

$rec = [ordered]@{
  ts         = $ts
  title      = $title
  frame_count= $frames
  last_frame = $last
  summary    = $summary
  salient    = $cap.salient
}

# Avoid duplicate write if last line has same ts
$needWrite = $true
if (Test-Path -LiteralPath $Jsonl) {
  $lastLine = Get-Content -LiteralPath $Jsonl -Tail 1 -ErrorAction SilentlyContinue
  if ($lastLine) {
    try {
      $lastObj = $lastLine | ConvertFrom-Json
      if ($lastObj.ts -eq $ts) { $needWrite = $false }
    } catch { }
  }
}

if ($needWrite) {
  ($rec | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $Jsonl -Encoding UTF8
}

# Trim file to the last $Retain lines
if (Test-Path -LiteralPath $Jsonl) {
  $lines = Get-Content -LiteralPath $Jsonl -ErrorAction SilentlyContinue
  if ($lines -and $lines.Count -gt $Retain) {
    $tail = $lines[-$Retain..-1]
    Set-Content -LiteralPath $Jsonl -Value $tail -Encoding UTF8
  }
}
