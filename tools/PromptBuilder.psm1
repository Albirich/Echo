function Build-ChatML {
  param(
    [string]$System, [string]$User,
    [string]$Tools = "", [string]$Memory = "", [string]$Persona = ""
  )
  # Prefer model-appropriate templating. If the selected model is Mistral,
  # emit [INST] format; otherwise use ChatML (<|im_start|> tags).

  $modelPath = $env:ECHO_LLAMACPP_MODEL
  $isMistral = $false
  try { if ($modelPath -and ($modelPath -match '(?i)mistral')) { $isMistral = $true } } catch {}

  # Build system block from Persona/Tools/Memory/System
  $sysParts = @()
  if ($Persona) { $sysParts += $Persona }
  if ($Tools)   { $sysParts += $Tools }
  if ($Memory)  { $sysParts += $Memory }
  if ($System)  { $sysParts += $System }
  $sysBlock = ($sysParts -join "`n").Trim()

  if ($isMistral) {
    # Mistral Instruct template
    # [INST] <<SYS>> <system> <</SYS>>\n<user> [/INST]\n
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[INST] ')
    if ($sysBlock) {
      [void]$sb.Append("<<SYS>>`n")
      [void]$sb.Append($sysBlock)
      [void]$sb.Append("`n<</SYS>>`n")
    }
    if ($User) { [void]$sb.Append($User) }
    [void]$sb.Append(' [/INST]')
    [void]$sb.Append("`n")
    return $sb.ToString()
  }

  # Default: ChatML
  # Pass-through mode: if System already contains ChatML tags, treat it as a prelude
  # and append the live user turn + assistant start.
  if ($System -and ($System.TrimStart() -like '<|im_start|>*')) {
    $prelude = $System.Trim()
    $tail = ""
    if ($User) { $tail += "<|im_start|>user`n$User<|im_end|>`n" }
    $tail += "<|im_start|>assistant`n"
    return ($prelude + "`n" + $tail)
  }

  $parts = @()
  if ($Persona) { $parts += "<|im_start|>system`n$Persona<|im_end|>" }
  if ($Tools)   { $parts += "<|im_start|>system`n$Tools<|im_end|>" }
  if ($Memory)  { $parts += "<|im_start|>system`n$Memory<|im_end|>" }
  if ($System)  { $parts += "<|im_start|>system`n$System<|im_end|>" }
  if ($User)    { $parts += "<|im_start|>user`n$User<|im_end|>" }
  $parts += "<|im_start|>assistant`n"
  return ($parts -join "`n")
}

function Get-TextOrEmpty { param([string]$Path)
  if (Test-Path $Path) { Get-Content $Path -Raw } else { "" }
}

Export-ModuleMember -Function Build-ChatML, Get-TextOrEmpty
