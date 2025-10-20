    $argsString = ($argList -join ' ')
    $logsDir = Join-Path $HomeDir 'logs'; Ensure-Dir $logsDir
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $outPath = Join-Path $logsDir ("llava-run-$ts.out.log")
    $errPath = Join-Path $logsDir ("llava-run-$ts.err.log")

    $p = Start-Process -FilePath $LlamaExe -ArgumentList $argsString -WorkingDirectory $HomeDir -RedirectStandardOutput $outPath -RedirectStandardError $errPath -WindowStyle Hidden -PassThru -Wait
    $stdout = try { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } catch { '' }
    $stderr = try { Get-Content -LiteralPath $errPath -Raw -Encoding UTF8 } catch { '' }
    if ($p.ExitCode -ne 0 -and -not $stdout.Trim()) {
      Write-Warning ("[VisionProbe] llama-mtmd-cli exit {0}: {1}" -f $p.ExitCode, ($stderr.Trim()))
    }
    return ($stdout.Trim())
