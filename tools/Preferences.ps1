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
    $raw = ConvertFrom-Json $json
    $prefs = As-Hashtable $raw
    if (-not ($prefs -is [hashtable])) { return @{ frames = @{} } }
    return $prefs
  } catch {
    Write-Warning "Preferences failed to load: $_"
    return @{ frames = @{} }
  }
}

function Save-Preferences($prefs) {
  $path = Join-Path $env:ECHO_HOME 'state/preferences.json'
  $dir  = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $json = $prefs | ConvertTo-Json -Depth 5
  Set-Content -Path $path -Value $json
}

function Get-PreferenceFrameNames {
  $Prefs = Get-Preferences
  if (-not $Prefs.frames) { return @() }
  return @($Prefs.frames.Keys)
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

  # Legacy hardcoded frames for backward compatibility
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

  # NEW: Dynamic frame matching - try to match tags to any available frame name
  if (-not $wantAll -and $Prefs.frames) {
    foreach ($frameName in $Prefs.frames.Keys) {
      $frameNameLow = $frameName.ToLower()
      # Check if any tag matches this frame name
      foreach ($tag in $tagsLow) {
        if ($frameNameLow -match $tag -or $tag -match $frameNameLow) {
          try {
            $frame = $Prefs.frames.$frameName
            if ($frame) {
              # Add all items from this frame with their scores
              foreach ($itemName in $frame.PSObject.Properties.Name) {
                $item = $frame.$itemName
                if ($item -and $item.PSObject.Properties['score']) {
                  $score = $item.score
                  $items += @{
                    id="pref:${frameName}:${itemName}";
                    snippet="${frameName}: ${itemName} (score: ${score})";
                    tags=@('preference',$frameName.ToLower());
                    score=$score
                  }
                }
              }
            }
          } catch {}
          break
        }
      }
    }
  }

  return ,$items
}

# ---------------- Additional helpers for inline updates ----------------
function As-Hashtable($obj) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [hashtable]) { return $obj }
  if ($obj -is [pscustomobject]) {
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = As-Hashtable $p.Value }
    return $h
  }
  if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
    return @($obj | ForEach-Object { As-Hashtable $_ })
  }
  return $obj
}
function Merge-Hashtable($target, $patch) {
  foreach ($k in $patch.Keys) {
    $pv = $patch[$k]
    if ($null -ne $target[$k] -and ($target[$k] -is [hashtable]) -and ($pv -is [hashtable])) {
      Merge-Hashtable -target $target[$k] -patch $pv | Out-Null
    } else {
      $target[$k] = $pv
    }
  }
  return $target
}

function Set-ByPath {
  param([hashtable]$Root, [string]$Path, $Value)
  $parts = $Path.Split('.')
  $cur = $Root
  for ($i=0; $i -lt $parts.Length; $i++) {
    $p = $parts[$i]
    if ($i -eq $parts.Length-1) {
      $cur[$p] = $Value
    } else {
      if (-not $cur.ContainsKey($p) -or -not ($cur[$p] -is [hashtable])) { $cur[$p] = @{} }
      $cur = $cur[$p]
    }
  }
}

function Update-PreferencesFromPatch {
  param([Parameter(Mandatory)][string]$PatchJson)
  $patch = $null
  try { $patch = As-Hashtable ($PatchJson | ConvertFrom-Json) } catch { throw "Invalid patch_json (must be JSON object)" }
  if (-not ($patch -is [hashtable])) { throw "patch_json must be a JSON object" }
  $prefs = Get-Preferences
  Merge-Hashtable -target $prefs -patch $patch | Out-Null
  Save-Preferences $prefs
  return @{ ok = $true; merged = @($patch.Keys) }
}

function Set-PreferenceByKey {
  param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$ValueJson)
  $prefs = Get-Preferences
  $val = $ValueJson
  try { $val = As-Hashtable ($ValueJson | ConvertFrom-Json) } catch { $val = $ValueJson }
  Set-ByPath -Root $prefs -Path $Key -Value $val | Out-Null
  Save-Preferences $prefs
  return @{ ok = $true; key = $Key }
}

function Invoke-PreferenceToolFromText {
  param([Parameter(Mandatory)][string]$Text)
  $result = @{ applied=$false }

  # 1) Try parse whole text as JSON tool call
  try {
    $obj = As-Hashtable ($Text | ConvertFrom-Json)
    if ($obj -and $obj.tool -and ($obj.tool -like 'preferences.*')) {
      if ($obj.tool -eq 'preferences.update' -and $obj.parameters -and $obj.parameters.patch_json) {
        $pr = Update-PreferencesFromPatch -PatchJson ([string]$obj.parameters.patch_json)
        return @{ applied=$true; tool='preferences.update'; detail=$pr }
      }
      if ($obj.tool -eq 'preferences.set' -and $obj.parameters -and $obj.parameters.key -and $obj.parameters.value_json) {
        $pr2 = Set-PreferenceByKey -Key ([string]$obj.parameters.key) -ValueJson ([string]$obj.parameters.value_json)
        return @{ applied=$true; tool='preferences.set'; detail=$pr2 }
      }
    }
  } catch {}

  # 2) Scan for embedded JSON blocks and apply first valid preference tool
  try {
    $regex = New-Object System.Text.RegularExpressions.Regex('{.*?}', 'Singleline')
    $m = $regex.Matches($Text)
    foreach ($mm in $m) {
      try {
        $obj2 = As-Hashtable ( ($mm.Value) | ConvertFrom-Json )
        if ($obj2 -and $obj2.tool -and ($obj2.tool -like 'preferences.*')) {
          if ($obj2.tool -eq 'preferences.update' -and $obj2.parameters -and $obj2.parameters.patch_json) {
            $pr3 = Update-PreferencesFromPatch -PatchJson ([string]$obj2.parameters.patch_json)
            return @{ applied=$true; tool='preferences.update'; detail=$pr3 }
          }
          if ($obj2.tool -eq 'preferences.set' -and $obj2.parameters -and $obj2.parameters.key -and $obj2.parameters.value_json) {
            $pr4 = Set-PreferenceByKey -Key ([string]$obj2.parameters.key) -ValueJson ([string]$obj2.parameters.value_json)
            return @{ applied=$true; tool='preferences.set'; detail=$pr4 }
          }
        }
      } catch {}
    }
  } catch {}

  # 3) Fallback: look for a patch_json literal string in text and apply
  try {
    $rx = New-Object System.Text.RegularExpressions.Regex('patch_json\s*[:=]\s*[\"\''](?<pj>\{.*?\})[\"\'']', 'Singleline')
    $mm2 = $rx.Match($Text)
    if ($mm2.Success) {
      $pj = $mm2.Groups['pj'].Value
      $pr5 = Update-PreferencesFromPatch -PatchJson $pj
      return @{ applied=$true; tool='preferences.update'; detail=$pr5; source='inline_patch_json' }
    }
  } catch {}

  return $result
}

# High-level helper: try tool JSON or simple heuristics; return details
function Apply-EmbeddedPreferenceUpdates {
  param([Parameter(Mandatory)][string]$Text)

  $res = @{ applied=$false; via=$null; detail=$null }
  try {
    $t = Invoke-PreferenceToolFromText -Text $Text
    if ($t -and $t.applied) { $res.applied = $true; $res.via = ($t.tool); $res.detail = $t.detail; return $res }
  } catch {}

  # Heuristics for common declarations like "favorite color is X"
  try {
    $lower = ($Text -replace '\r\n?', ' ').ToLower()
    $patch = $null

    # Favorite color
    $m = [regex]::Match($lower, '(?:my\s+)?favorite\s+color\s*(?:is|:)\s*([a-z\- ]{3,20})')
    if ($m.Success) {
      $color = ($m.Groups[1].Value.Trim() -replace '[^a-z]+',' ' -replace '\s+',' ').Trim()
      if ($color) {
        $patch = @{ frames = @{ 'Colors' = @{} } }
        $patch.frames['Colors'][$color] = @{ score = 0.9 }
      }
    }

    # Favorite animal
    if (-not $patch) {
      $m2 = [regex]::Match($lower, '(?:my\s+)?favorite\s+animal\s*(?:is|:)\s*([a-z\- ]{3,30})')
      if ($m2.Success) {
        $animal = ($m2.Groups[1].Value.Trim() -replace '[^a-z]+',' ' -replace '\s+',' ').Trim()
        if ($animal) {
          $patch = @{ frames = @{ 'Animals' = @{} } }
          $patch.frames['Animals'][$animal] = @{ score = 0.9 }
        }
      }
    }

    # Favorite comfort food
    if (-not $patch) {
      $m3 = [regex]::Match($lower, '(?:my\s+)?favorite\s+comfort\s+food\s*(?:is|:)\s*([a-z\- ]{3,40})')
      if ($m3.Success) {
        $food = ($m3.Groups[1].Value.Trim() -replace '[^a-z]+',' ' -replace '\s+',' ').Trim()
        if ($food) {
          $patch = @{ frames = @{ 'Comfort Foods' = @{} } }
          $patch.frames['Comfort Foods'][$food] = @{ score = 0.9 }
        }
      }
    }

    if ($patch) {
      $prefs = Get-Preferences
      Merge-Hashtable -target $prefs -patch $patch | Out-Null
      Save-Preferences $prefs
      $res.applied = $true
      $res.via = 'heuristic'
      $res.detail = $patch
      return $res
    }
  } catch {}

  return $res
}
