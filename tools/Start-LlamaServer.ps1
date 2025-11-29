[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ModelPath,

    [string]$ServerPath = 'D:\llama-cpp\llama-server.exe',
    [string]$ListenHost       = '127.0.0.1',
    [int]$Port          = 8080,

    # Performance knobs
    [int]$Threads       = 4 ,
    [int]$ThreadsBatch  = $Threads,
    [int]$Batch         = 1024,
    [int]$Ctx           = 4096,
    [int]$Ngl           = 999,

    # Prompt-cache (RAM) control. Use -DisableCache to turn off entirely.
    [int]$CacheRamMB    = 2048,
    [switch]$DisableCache,

    # Optional flags
    [switch]$NoMmap,
    [switch]$EnableMMQ,      # sets GGML_CUDA_FORCE_MMQ=1 for this launch
    [switch]$KillExisting,   # stop any running llama-server first
    [switch]$Foreground,     # run in-foreground and tee output to .out.log

    # Logging
    [string]$LogDir = 'D:\Echo\logs',

    # Back-compat: allow a raw argument string to be appended (e.g., "-fa 1 --temp 0.8")
    [string]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PathExists([string]$Path, [string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Missing {0}: {1}" -f $Kind, $Path)
    }
}


# Robustly split a command-line string into tokens (handles quotes)
function Split-ExtraArgs {
    param([string]$Line)
    if (-not $Line -or $Line.Trim().Length -eq 0) { return @() }

    Add-Type -ErrorAction SilentlyContinue -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArgvHelper {
  [DllImport("shell32.dll", SetLastError=true)]
  private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);
  [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr hMem);
  public static string[] Split(string cmd) {
    if (string.IsNullOrWhiteSpace(cmd)) return new string[0];
    int n; IntPtr p = CommandLineToArgvW(cmd, out n);
    if (p == IntPtr.Zero) return new string[]{cmd};
    try {
      var a = new string[n];
      for (int i=0;i<n;i++) {
        IntPtr s = System.Runtime.InteropServices.Marshal.ReadIntPtr(p, i*IntPtr.Size);
        a[i] = System.Runtime.InteropServices.Marshal.PtrToStringUni(s);
      }
      return a;
    } finally { LocalFree(p); }
  }
}
'@

    return [ArgvHelper]::Split($Line)
}

# --- Prep ---
Assert-PathExists -Path $ServerPath -Kind 'llama-server.exe'
Assert-PathExists -Path $ModelPath  -Kind 'model file'

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

if ($KillExisting) {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Per-process env for this launch
if ($EnableMMQ) { $env:GGML_CUDA_FORCE_MMQ = '1' }

# --- Build argument list ---
$cli = @(
    '-m', $ModelPath,
    '-ngl', $Ngl,
    '-t', $Threads,
    '-tb', $ThreadsBatch,
    '-b', $Batch,
    '-c', $Ctx,
    '--host', $ListenHost,
    '--port', $Port
)

if ($DisableCache) {
    $cli += @('--cache-ram','0')
} else {
    if ($CacheRamMB -ge 0) { $cli += @('--cache-ram', "$CacheRamMB") }
}

if ($NoMmap) { $cli += '--no-mmap' }

$extra = Split-ExtraArgs -Line $Args
if ($extra.Count -gt 0) { $cli += $extra }

# --- Logging files ---
$ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
$out = Join-Path $LogDir "llama-server-$ts.out.log"
$err = Join-Path $LogDir "llama-server-$ts.err.log"

Write-Host "Launching llama-server with:" -ForegroundColor Cyan
Write-Host ("  Threads/Batch: -t {0} -tb {1} -b {2} -c {3}" -f $Threads, $ThreadsBatch, $Batch, $Ctx)
Write-Host ("  Offload:      -ngl {0}" -f $Ngl)
Write-Host ("  Host/Port:    {0}:{1}" -f $ListenHost, $Port)
if ($DisableCache) { Write-Host "  Cache-RAM:    disabled" } else { Write-Host ("  Cache-RAM:    {0} MiB" -f $CacheRamMB) }
if ($EnableMMQ) { Write-Host "  GGML_CUDA_FORCE_MMQ=1" }
if ($NoMmap)     { Write-Host "  --no-mmap enabled" }
if ($extra.Count) { Write-Host ("  Extra args:   {0}" -f ($extra -join ' ')) }
Write-Host ("  Logs:         `n    OUT: {0}`n    ERR: {1}" -f $out, $err)

# --- Launch ---
if ($Foreground) {
    Write-Host "Running in foreground (Ctrl+C to stop)..." -ForegroundColor Yellow
    & $ServerPath @cli *>&1 | Tee-Object -FilePath $out
}
else {
    Start-Process -FilePath $ServerPath -ArgumentList $cli -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null
    Start-Sleep -Milliseconds 250
    $procs = Get-Process llama-server -ErrorAction SilentlyContinue | Select-Object Id,Path
    if ($procs) {
        Write-Host "Started llama-server:" -ForegroundColor Green
        $procs | Format-Table -AutoSize | Out-String | Write-Host
    } else {
        Write-Warning "llama-server did not appear in process list; check $err"
    }
}

# --- Helpful tail command to verify GPU usage ---
Write-Host "Tip: Verify GPU offload with:" -ForegroundColor DarkGray
Write-Host ("  Select-String -Path '{0}' -Pattern 'using device CUDA0|offloaded 33/33|KV buffer size|compute buffer size|n_threads'" -f $err)
