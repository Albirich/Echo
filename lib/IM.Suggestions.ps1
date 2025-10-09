# D:\Echo\lib\IM.Suggestions.ps1
# Helpers to persist and read recent IM suggestions for last-minute dedupe

function __imGetHome {
  if ($env:ECHO_HOME -and $env:ECHO_HOME.Trim()) { return $env:ECHO_HOME }
  return 'D:\Echo'
}
function __imEnsureDir([string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}
function __imGetSuggestionsPath {
  $home = __imGetHome
  $state = Join-Path $home 'state'
  __imEnsureDir $state
  $p = Join-Path $state 'suggestions.json'
  if (-not (Test-Path $p)) { Set-Content -Path $p -Value '[]' -Encoding UTF8 }
  return $p
}
function ConvertFrom-JsonSafe {
  param([string]$Text)
  try {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    return $Text | ConvertFrom-Json -ErrorAction Stop
  } catch { return $null }
}
function Get-StringHash {
  param([string]$Text)
  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
  $hash = $sha1.ComputeHash($bytes)
  return -join ($hash | ForEach-Object { $_.ToString('x2') })
}
function Get-SuggestionSignature {
  param($sugg)
  $txt = $null
  if ($sugg -is [string]) {
    $txt = $sugg
  } else {
    try {
      $json = $sugg | ConvertTo-Json -Depth 10 -Compress
      if ($json -and $json.Length -gt 512) { $json = $json.Substring(0,512) }
      $txt = $json
    } catch { $txt = '' }
  }
  if (-not $txt) { $txt = [string]$sugg }
  return (Get-StringHash ($txt.ToLower()))
}
function Read-AllSuggestions {
  $p = __imGetSuggestionsPath
  try {
    $raw = Get-Content -Path $p -Raw -ErrorAction Stop
    $arr = ConvertFrom-JsonSafe $raw
    if ($arr -isnot [System.Collections.IEnumerable]) { return @() }
    return @($arr)
  } catch { return @() }
}
function Write-AllSuggestions {
  param($arr)
  $p = __imGetSuggestionsPath
  $max = 1000
  $list = @($arr)
  $count = $list.Count
  if ($count -gt $max) {
    $start = $count - $max
    $list  = $list[$start..($count-1)]
  }
  ($list | ConvertTo-Json -Depth 10) | Set-Content -Path $p -Encoding UTF8
}
function Add-Suggestions {
  param($suggestions, [string]$source = 'IM')
  if (-not $suggestions) { return }

  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $all = Read-AllSuggestions

  foreach ($s in @($suggestions)) {
    # normalize to hashtable
    $obj = @{}
    if     ($s -is [string])       { $obj['text'] = $s }
    elseif ($s -is [hashtable])    { $obj = @{} + $s }
    elseif ($s -is [pscustomobject]) {
      foreach ($p in $s.PSObject.Properties) { $obj[$p.Name] = $p.Value }
      if (-not $obj) { $obj = @{} }
    } else {
      try {
        $tmp = ($s | ConvertTo-Json -Depth 10) | ConvertFrom-Json
        foreach ($p in $tmp.PSObject.Properties) { $obj[$p.Name] = $p.Value }
      } catch { $obj = @{} }
    }

    # text fallback (PS 5.1-safe)
    $textVal = ''
    if     ($obj.ContainsKey('text')    -and $obj['text'])    { $textVal = [string]$obj['text'] }
    elseif ($obj.ContainsKey('content') -and $obj['content']) { $textVal = [string]$obj['content'] }
    elseif ($obj.ContainsKey('name')    -and $obj['name'])    { $textVal = [string]$obj['name'] }
    $obj['text']   = $textVal
    $obj['t']      = $nowMs
    $obj['source'] = $source

    if ($obj.ContainsKey('signature') -and $obj['signature']) {
      $sig = [string]$obj['signature']
    } else {
      $sig = Get-SuggestionSignature $s
      $obj['signature'] = $sig
    }

    $all += ,$obj
  }

  Write-AllSuggestions $all
}
function Get-RecentSuggestionsSince {
  param([int]$Seconds = 60)
  $all = Read-AllSuggestions
  if (-not $all) { return @() }
  $now  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $edge = $now - ($Seconds * 1000)
  $recent = $all | Where-Object { $_.t -ge $edge } | Sort-Object t -Descending

  # de-dup by signature (keep newest)
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $out  = New-Object System.Collections.ArrayList
  foreach ($it in $recent) {
    $sig = [string]$it.signature
    if (-not $sig) { $sig = Get-SuggestionSignature $it }
    if ($seen.Add($sig)) { [void]$out.Add($it) }
    if ($out.Count -ge 120) { break }
  }
  return @($out)
}
