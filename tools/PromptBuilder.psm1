function Build-ChatML {
  param(
    [string]$System, [string]$User,
    [string]$Tools = "", [string]$Memory = "", [string]$Persona = ""
  )
  # Pass-through mode: if System already contains ChatML tags, treat it as a prelude
  # and append the live user turn + assistant start. This allows fully structured
  # system prompts without double-wrapping.
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
