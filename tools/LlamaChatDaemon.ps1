[CmdletBinding()]
param(
  [int]$PollMs = 200,
  [string]$ModelPath = "D:\Echo\models\DarkIdol-Llama-3.1-8B-Instruct-1.2-Uncensored.Q5_K_M.gguf",
  [string]$LlamaExe  = "D:\llama-cpp\llama-cli.exe"
)

$ErrorActionPreference = 'Stop'

function Ensure-Dir($p){ if(-not(Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Append-Jsonl([string]$Path,[object]$Obj){ $line = ($Obj | ConvertTo-Json -Depth 10 -Compress) + "`n"; Add-Content -LiteralPath $Path -Value $line -Encoding UTF8 }

# Resolve Echo root robustly (prefer ECHO_HOME, else parent of tools)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$parentRoot = Split-Path -Parent $scriptRoot
if ($env:ECHO_HOME -and (Test-Path $env:ECHO_HOME)) {
  $EchoRoot = $env:ECHO_HOME
} elseif (Test-Path (Join-Path $parentRoot 'ui')) {
  $EchoRoot = $parentRoot
} else {
  $EchoRoot = $scriptRoot
}
$UI   = Join-Path $EchoRoot 'ui'
$INBX = Join-Path $UI 'inboxq'; Ensure-Dir $INBX
$OUTB = Join-Path $UI 'outbox.jsonl'; if(!(Test-Path $OUTB)){ [IO.File]::WriteAllText($OUTB,'',[Text.UTF8Encoding]::new($false)) }
$LOGS = Join-Path $EchoRoot 'logs'; Ensure-Dir $LOGS
$PPTH = Join-Path $LOGS 'prompts'; Ensure-Dir $PPTH

Import-Module (Join-Path $EchoRoot 'tools\PromptBuilder.psm1') -Force -DisableNameChecking

Append-Jsonl $OUTB @{ ts=(Get-Date).ToString('o'); kind='system'; channel='daemon'; event='llama.daemon.ready'; model=(Split-Path $ModelPath -Leaf); inbox=$INBX; root=$EchoRoot; poll_ms=$PollMs }
Write-Output ("[llama-daemon] Ready. Inbox: {0}" -f $INBX)

${idleCount} = 0
${heartbeatEvery} = [Math]::Max([int](10000 / [Math]::Max($PollMs,1)), 3)  # ~10s worth of polls, min 3
while ($true) {
  try {
    $files = Get-ChildItem -LiteralPath $INBX -File -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
    if (-not $files -or $files.Count -eq 0) {
      ${idleCount}++
      if (${idleCount} -ge ${heartbeatEvery}) {
        Append-Jsonl $OUTB @{ ts=(Get-Date).ToString('o'); kind='system'; channel='daemon'; event='llama.daemon.heartbeat'; inbox=$INBX }
        ${idleCount} = 0
      }
      Start-Sleep -Milliseconds $PollMs; continue
    }
    ${idleCount} = 0
    foreach ($next in $files) {
      Append-Jsonl $OUTB @{ ts=(Get-Date).ToString('o'); kind='system'; channel='daemon'; event='llama.daemon.pick'; file=$next.FullName }
      Write-Output ("[llama-daemon] Pick: {0}" -f $next.FullName)

      # Read content immediately (files are created per message)
      $text = ''
      try { $text = Get-Content -LiteralPath $next.FullName -Raw -Encoding UTF8 } catch { $text = '' }

      # Remove regardless to avoid piling up
      try { Remove-Item -LiteralPath $next.FullName -Force -ErrorAction SilentlyContinue } catch { }

      if (-not $text -or $text.Trim().Length -eq 0) {
        Append-Jsonl $OUTB @{ ts=(Get-Date).ToString('o'); kind='system'; channel='daemon'; event='llama.daemon.skip'; reason='empty_or_read_fail'; file=$next.FullName }
        continue
      }

      # Log user message with length
      Append-Jsonl $OUTB @{ ts=(Get-Date).ToString('o'); kind='user'; text=$text; len=$text.Length }

      # Build prompt
      $tools   = Get-TextOrEmpty (Join-Path $EchoRoot 'prompts\echo-tools.txt')
      $memory  = Get-TextOrEmpty (Join-Path $EchoRoot 'memory\shallow.md')
      $persona = Get-TextOrEmpty (Join-Path $EchoRoot 'prompts\persona.brain.md')
      $system  = Get-TextOrEmpty (Join-Path $EchoRoot 'prompts\system.base.md')
      $prompt  = Build-ChatML -System $system -User $text -Tools $tools -Memory $memory -Persona $persona

      $ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
      $pf = Join-Path $PPTH ("chat_{0}.txt" -f $ts)
      [IO.File]::WriteAllText($pf, $prompt, [Text.UTF8Encoding]::new($false))

      # Run llama.cpp (this appends the assistant text to outbox.jsonl)
      try {
        powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $EchoRoot 'tools\Start-LocalLLM.ps1') -PromptFile $pf -ModelPath $ModelPath -LlamaExe $LlamaExe | Out-Null
      } catch {
        Append-Jsonl $OUTB @{ ts=(Get-Date).ToString('o'); kind='system'; channel='daemon'; event='llama.daemon.proc.err'; error=$_.Exception.Message; file=$next.FullName }
      }
    }
  } catch {
    Append-Jsonl $OUTB @{ ts=(Get-Date).ToString('o'); kind='system'; channel='daemon'; event='llama.daemon.err'; error=$_.Exception.Message }
    Start-Sleep -Milliseconds 500
  }
}
