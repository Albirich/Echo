<#  Start-EchoAll.ps1 — lean launcher for 4 processes
    - Start-Echo.ps1
    - Start-IM.ps1
    - Start-EchoRoom.ps1
    - tools\Start-VisionProbe-Lite.ps1
#>

# ---------- strict-ish ----------
$ErrorActionPreference = 'Stop'

[CmdletBinding()]
param(
    [switch]$WithWhisper,
    [string]$WhisperArgs = $env:ECHO_START_WHISPER_ARGS
)

# Import core modules ONCE (parent only)
# If these aren't available for any reason, we still fall back to .NET where possible.
Import-Module Microsoft.PowerShell.Management   -ErrorAction SilentlyContinue
Import-Module Microsoft.PowerShell.Utility      -ErrorAction SilentlyContinue

# ---------- tiny logger ----------
function Write-Info ([string]$msg) { [Console]::WriteLine("[EchoAll] {0}"      -f $msg) }
function Write-Warn ([string]$msg) { [Console]::WriteLine("[EchoAll][WARN] {0}" -f $msg) }
function Write-Err  ([string]$msg) { [Console]::WriteLine("[EchoAll][ERR]  {0}" -f $msg) }

# ---------- helpers ----------
function Assert-PathExists([string]$Path, [string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Missing {0}: {1}" -f $Kind, $Path)
    }
}

# Start a child PS (prefers PS7), imports core modules in the CHILD, logs to ./logs
function Start-DetachedChild {
    param(
        [Parameter(Mandatory)][string]$File,
        [string]$Args = '',
        [string]$Name = ''
    )

    # pick shell
    $ps7  = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $ps7) { $psExe = $ps7 }
    else { $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

    # logs folder
    if (-not (Test-Path -LiteralPath $script:logs)) {
        New-Item -ItemType Directory -Force -Path $script:logs | Out-Null
    }
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    if ($Name -and $Name.Trim().Length -gt 0) { $prefix = $Name } else { $prefix = 'child' }
    $outLog = Join-Path $script:logs ("{0}-{1}.out.log" -f $prefix, $ts)
    $errLog = Join-Path $script:logs ("{0}-{1}.err.log" -f $prefix, $ts)

    # safe quoting
    $fileEsc = $File.Replace("'", "''")
    $cmd = "Import-Module Microsoft.PowerShell.Utility,Microsoft.PowerShell.Management; & '$fileEsc' $Args"

    $p = Start-Process -FilePath $psExe `
        -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NonInteractive','-Command', $cmd) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError  $errLog `
        -PassThru

    try { $p.PriorityClass = 'BelowNormal' } catch {}

    if (-not (Get-Variable children -Scope Script -ErrorAction SilentlyContinue)) { $script:children = @{} }
    if ($Name -and $Name.Trim().Length -gt 0) { $script:children[$Name] = $p }

    if ($Name -and $Name.Trim().Length -gt 0) {
        Write-Info ("Started {0} (PID {1})" -f $Name, $p.Id)
    } else {
        Write-Info ("Started child (PID {0})" -f $p.Id)
    }

    return $p
}

function Stop-AllChildren {
    if (-not (Get-Variable children -Scope Script -ErrorAction SilentlyContinue)) { return }
    foreach ($k in $children.Keys) {
        try {
            $proc = $children[$k]
            if ($proc -and -not $proc.HasExited) {
                Write-Warn ("Stopping {0} (PID {1})" -f $k, $proc.Id)
                $proc.Kill()
            }
        } catch {
            Write-Warn ("Failed to stop {0}: {1}" -f $k, $_.Exception.Message)
        }
    }
}

# ---------- parent: lower our own footprint ----------
try {
    $self = [System.Diagnostics.Process]::GetCurrentProcess()
    $self.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    # Optional: restrict to first 4 logical cores -> uncomment if wanted
    # $self.ProcessorAffinity = [intptr] 0x0F
} catch {
    Write-Warn ("Could not adjust parent priority/affinity: {0}" -f $_.Exception.Message)
}

# ---------- resolve ECHO_HOME and directories ----------
# PSScriptRoot works when script file is on disk; fallback to $MyInvocation if needed
if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
    $ScriptRoot = $PSScriptRoot
} else {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $env:ECHO_HOME -or -not (Test-Path -LiteralPath $env:ECHO_HOME)) {
    $env:ECHO_HOME = $ScriptRoot
}
$HOME_DIR = $env:ECHO_HOME

$script:logs  = Join-Path $HOME_DIR 'logs'
$uiPath       = Join-Path $HOME_DIR 'ui'
$inboxq       = Join-Path $uiPath    'inboxq'
$outbox       = Join-Path $uiPath    'outbox.jsonl'
$stateDir     = Join-Path $HOME_DIR  'state'
New-Item -ItemType Directory -Force -Path $script:logs,$uiPath,$inboxq,$stateDir | Out-Null
if (-not (Test-Path -LiteralPath $outbox)) {
    [IO.File]::WriteAllText($outbox, '', [Text.UTF8Encoding]::new($false))
}

# host gating flag (VisionLite)
$hostFlag = Join-Path $stateDir 'host.flag'
$env:ECHO_HOST_FLAG = $hostFlag
if (-not (Test-Path -LiteralPath $hostFlag)) {
    [IO.File]::WriteAllText($hostFlag, 'ok', [Text.UTF8Encoding]::new($false))
}

# ---------- prefer llama.cpp everywhere ----------
$env:ECHO_USE_LLAMA_CPP      = '1'
$env:ECHO_IM_USE_LLAMA_CPP   = '1'

# pick models (favor Noromaid 7B Q4_K_M)
$noromaid = Join-Path $HOME_DIR 'models\athirdpath-NSFW_DPO_Noromaid-7b-Q4_K_M.gguf'
$altGemma = Join-Path $HOME_DIR 'models\gemma-3-4b-it-uncensored-dbl-x-q8_0.gguf'

if (Test-Path -LiteralPath $noromaid) {
    $env:ECHO_LLAMACPP_MODEL = $noromaid
} elseif (Test-Path -LiteralPath $altGemma) {
    $env:ECHO_LLAMACPP_MODEL = $altGemma
} else {
    if ($env:ECHO_LLAMACPP_MODEL) { Remove-Item Env:ECHO_LLAMACPP_MODEL -ErrorAction SilentlyContinue }
}

# router + IM same model
$env:ECHO_ROUTER_LLAMACPP_MODEL = $noromaid
$env:ECHO_IM_LLAMACPP_MODEL     = $noromaid

# show models
if ($env:ECHO_LLAMACPP_MODEL) { Write-Info ("Chat model: {0}"   -f $env:ECHO_LLAMACPP_MODEL) } else { Write-Info "Chat model: (auto)" }
Write-Info ("Router model: {0}" -f $env:ECHO_ROUTER_LLAMACPP_MODEL)

# force all → IM if present
try {
    if ($env:ECHO_IM_LLAMACPP_MODEL -and (Test-Path -LiteralPath $env:ECHO_IM_LLAMACPP_MODEL)) {
        $env:ECHO_LLAMACPP_MODEL        = $env:ECHO_IM_LLAMACPP_MODEL
        $env:ECHO_ROUTER_LLAMACPP_MODEL = $env:ECHO_IM_LLAMACPP_MODEL
        Write-Info ("Forcing all models to IM model: {0}" -f $env:ECHO_IM_LLAMACPP_MODEL)
    }
} catch {}

# ---------- backend tuning (low CPU, push to GPU) ----------
$env:OLLAMA_NUM_GPU      = '999'
if ($env:ECHO_IM_BACKEND) { Remove-Item Env:ECHO_IM_BACKEND -ErrorAction SilentlyContinue }

$env:ECHO_LLAMA_THREADS      = '1'
$env:ECHO_LLAMA_MAIN_GPU     = '0'
if (-not $env:ECHO_IM_THREADS      -or -not $env:ECHO_IM_THREADS.Trim())      { $env:ECHO_IM_THREADS      = '1' }
if (-not $env:ECHO_VISION_THREADS  -or -not $env:ECHO_VISION_THREADS.Trim())  { $env:ECHO_VISION_THREADS  = '1' }
$env:ECHO_LLAMA_BATCH        = '512'
$env:ECHO_LLAMA_UBATCH       = '128'

# Llama server endpoint (if your brain/IM talk to llama.cpp server)
if (-not $env:ECHO_LLAMA_SERVER -or -not $env:ECHO_LLAMA_SERVER.Trim()) {
    $env:ECHO_LLAMA_SERVER = 'http://127.0.0.1:8080/v1'
}
if (-not $env:ECHO_LLAMA_MODEL  -or -not $env:ECHO_LLAMA_MODEL.Trim()) {
    # should match --alias in Start-LlamaServer.ps1 if you use it
    $env:ECHO_LLAMA_MODEL = 'echo'
}

# ---------- child script paths ----------
$pathEcho    = Join-Path $HOME_DIR 'Start-Echo.ps1'
$pathIM      = Join-Path $HOME_DIR 'Start-IM.ps1'
$pathRoom    = Join-Path $HOME_DIR 'Start-EchoRoom.ps1'
$pathVision  = Join-Path $HOME_DIR 'tools\Start-VisionProbe-Lite.ps1'

Assert-PathExists $pathEcho   'child script'
Assert-PathExists $pathIM     'child script'
Assert-PathExists $pathRoom   'child script'
Assert-PathExists $pathVision 'child script'

$pathWhisper = Join-Path $HOME_DIR 'tools\Start-WhisperStreamToInbox.ps1'

Write-Info "Using:"
Write-Info ("  Echo      : {0}" -f $pathEcho)
Write-Info ("  IM        : {0}" -f $pathIM)
Write-Info ("  EchoRoom  : {0}" -f $pathRoom)
Write-Info ("  VisionLite: {0}" -f $pathVision)

if ($WithWhisper -or ($env:ECHO_START_WHISPER -and $env:ECHO_START_WHISPER.Trim() -in @('1','true','yes','on'))) {
    if (Test-Path -LiteralPath $pathWhisper) {
        Write-Info ("  Whisper   : {0}" -f $pathWhisper)
    } else {
        Write-Warn ("  Whisper   : requested but script missing: {0}" -f $pathWhisper)
    }
} else {
    Write-Info ("  Whisper   : (disabled)")
}

# ---- Vision rolling context (seed once, no watchers) ----
if (-not $env:ECHO_VISION_LAST -or -not $env:ECHO_VISION_LAST.Trim()) { $env:ECHO_VISION_LAST = '6' }

$appendScript = Join-Path $env:ECHO_HOME 'tools\Append-ScreenCaption.ps1'
$latestCap    = Join-Path $env:ECHO_HOME 'ui\screen.caption.json'
$jsonlCaps    = Join-Path $env:ECHO_HOME 'ui\screen.captions.jsonl'

if (Test-Path -LiteralPath $appendScript) {
  try {
    & $appendScript -Latest $latestCap -Jsonl $jsonlCaps -Retain 200 | Out-Null
  } catch { }
}


# ---------- launch children ----------
$children = @{}
Start-DetachedChild -File $pathEcho   -Name 'Echo'      | Out-Null
Start-DetachedChild -File $pathIM     -Name 'IM'        | Out-Null
Start-DetachedChild -File $pathRoom   -Name 'EchoRoom'  | Out-Null
Start-DetachedChild -File $pathVision -Name 'VisionLite'| Out-Null

if ($WithWhisper -or ($env:ECHO_START_WHISPER -and $env:ECHO_START_WHISPER.Trim() -in @('1','true','yes','on'))) {
    if (Test-Path -LiteralPath $pathWhisper) {
        $args = if ($WhisperArgs) { $WhisperArgs } else { '' }
        Start-DetachedChild -File $pathWhisper -Args $args -Name 'Whisper' | Out-Null
    } else {
        Write-Warn "Whisper requested but not started (missing script)."
    }
} else {
    Write-Info "Whisper not started (disabled)."
}

# print PID map (no pipeline-in-string shenanigans)
$pairList = @()
foreach ($k in $children.Keys) {
    $p = $children[$k]
    if ($p) { $pairList += ("{0}={1}" -f $k, $p.Id) }
}
if ($pairList.Count -gt 0) {
    $pidLine = [string]::Join(', ', ($pairList | Sort-Object))
    Write-Info ("PIDs: {0}" -f $pidLine)
}

# ---------- optional: keep the launcher alive; Ctrl+C to stop kids ----------
# Remove the wait loop if you don't want the launcher to hold the console.
try {
    Write-Info "Press Ctrl+C to stop all children..."
    while ($true) { Start-Sleep -Seconds 3600 }
} catch {
    Write-Warn "Interrupt received; stopping children..."
    Stop-AllChildren
    Write-Info "All children stopped."
}
