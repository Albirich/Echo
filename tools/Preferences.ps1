function Get-TopPreference($prefs, $frameName) {
  $frames = $prefs.frames
  if (-not $frames) { return $null }

  $frame = $frames.$frameName
  if (-not $frame) { return $null }

  return $frame.PSObject.Properties |
    Where-Object { $_.Value -and $_.Value.PSObject.Properties["score"] } |
    Sort-Object { $_.Value.score } -Descending |
    Select-Object -First 1
}

function Get-Preferences {
  $path = Join-Path $env:ECHO_HOME 'state/preferences.json'
  if (-not (Test-Path $path)) {
    $seed = Join-Path $env:ECHO_HOME 'config/preferences.seed.json'
    if (Test-Path $seed) { Copy-Item $seed $path }
    else { Set-Content -Path $path -Value '{}' }
  }
  try {
    $json = Get-Content $path -Raw
    $prefs = ConvertFrom-Json $json
    if ($prefs -is [System.Collections.Hashtable]) { return $prefs }
    return @{'frames' = $prefs.frames}
  } catch {
    Write-Warning "Preferences failed to load: $_"
    return @{ frames = @{} }
  }
}

function Save-Preferences($prefs) {
  $path = Join-Path $env:ECHO_HOME 'state/preferences.json'
  $json = $prefs | ConvertTo-Json -Depth 5
  Set-Content -Path $path -Value $json
}

function Get-PreferencesSummary {
  param($Prefs)
  if (-not $Prefs) { $Prefs = Get-Preferences }
  $lines = @()
  try {
    $topColor  = Get-TopPreference -prefs $Prefs -frameName 'Colors'
    $topAnimal = Get-TopPreference -prefs $Prefs -frameName 'Animals'
    $topFood   = Get-TopPreference -prefs $Prefs -frameName 'Comfort Foods'
    if ($topColor)  { $lines += ("Favorite color: "  + $topColor.Name) }
    if ($topAnimal) { $lines += ("Favorite animal: " + $topAnimal.Name) }
    if ($topFood)   { $lines += ("Favorite comfort food: " + $topFood.Name) }
  } catch {}
  return ($lines -join "`n")
}

function Get-PreferencesByTags {
  param([string[]]$Tags)
  $Prefs = Get-Preferences
  $items = @()
  $tagsLow = @($Tags | ForEach-Object { ("" + $_).ToLower() })
  $wantAll = (-not $Tags -or $Tags.Count -eq 0)

  try {
    if ($wantAll -or ($tagsLow -match 'color').Count -gt 0) {
      $c = Get-TopPreference -prefs $Prefs -frameName 'Colors'
      if ($c) { $items += @{ id='pref:favorite_color'; snippet=("Favorite color: " + $c.Name); tags=@('preference','color') } }
    }
  } catch {}
  try {
    if ($wantAll -or ($tagsLow -match 'animal').Count -gt 0) {
      $a = Get-TopPreference -prefs $Prefs -frameName 'Animals'
      if ($a) { $items += @{ id='pref:favorite_animal'; snippet=("Favorite animal: " + $a.Name); tags=@('preference','animal') } }
    }
  } catch {}
  try {
    if ($wantAll -or ($tagsLow -match 'food|comfort').Count -gt 0) {
      $f = Get-TopPreference -prefs $Prefs -frameName 'Comfort Foods'
      if ($f) { $items += @{ id='pref:favorite_food'; snippet=("Favorite comfort food: " + $f.Name); tags=@('preference','food') } }
    }
  } catch {}

  return ,$items
}
