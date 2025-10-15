#requires -Version 5.1
Set-StrictMode -Version Latest

$script:ECHO_HOME = $env:ECHO_HOME
if (-not $script:ECHO_HOME) { $script:ECHO_HOME = (Resolve-Path ".").Path }

function Get-DeepMemoryPath {
  param([string]$Path)
  if ($Path) { return $Path }
  return (Join-Path $script:ECHO_HOME "memory\deep.jsonl")
}

function ConvertFrom-JsonL {
  param(
    [Parameter(Mandatory)]
    [System.IO.StreamReader]$Reader
  )
  while (-not $Reader.EndOfStream) {
    $line = $Reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $obj = $line | ConvertFrom-Json -Depth 32
      [pscustomobject]@{ __raw = $line; __obj = $obj }
    } catch { continue }
  }
}

function Open-SharedReader {
  param([string]$Path)
  $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  return (New-Object System.IO.StreamReader($fs))
}

function Normalize-Tags {
  param([object]$TagsField)
  if ($TagsField -is [string]) {
    return (@($TagsField -split '[,\|\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToLowerInvariant() })) | Select-Object -Unique
  } elseif ($TagsField -is [System.Collections.IEnumerable]) {
    return (@($TagsField | ForEach-Object { "$_".ToLowerInvariant() })) | Select-Object -Unique
  } else { return @() }
}

function New-MemoryId { param([int]$LineNo) "deep:$LineNo" }
function Parse-MemoryId {
  param([string]$Id)
  if ($Id -match '^deep:(\d+)$') { return [int]$Matches[1] }
  throw "Unsupported memory id format: $Id"
}

function Parse-QueryTokens {
  param([string]$Query)
  if (-not $Query) { return @() }
  $pattern = '"([^"]+)"|(\S+)'
  $m = [regex]::Matches($Query, $pattern)
  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($x in $m) {
    if ($x.Groups[1].Success) { [void]$tokens.Add($x.Groups[1].Value) }
    elseif ($x.Groups[2].Success) { [void]$tokens.Add($x.Groups[2].Value) }
  }
  return ,$tokens.ToArray()
}

function Get-DeepMemoryById {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Id,
    [string]$Path
  )
  $path = Get-DeepMemoryPath -Path $Path
  if (-not (Test-Path -LiteralPath $path)) { throw "Memory file not found: $path" }
  $lineNo = Parse-MemoryId $Id

  $sr = Open-SharedReader -Path $path
  try {
    $i = 0
    while (-not $sr.EndOfStream) {
      $line = $sr.ReadLine()
      if ($i -eq $lineNo) {
        try { $obj = $line | ConvertFrom-Json -Depth 32 } catch { throw "Corrupt JSON at line $lineNo" }
        return [pscustomobject]@{
          id      = $Id
          ts      = $obj.ts
          tags    = $obj.tags
          source  = $obj.source
          content = $obj.content
          raw     = $line
          line    = $lineNo
        }
      }
      $i++
    }
    throw "Id not found (past EOF): $Id"
  } finally { $sr.Dispose() }
}

function Search-DeepMemory {
  [CmdletBinding()]
  param(
    [string]$Query,
    [string[]]$Tags,
    [string[]]$Sources,
    [datetime]$After,
    [datetime]$Before,
    [int]$Limit = 10,
    [switch]$IncludeContent,
    [string]$Path
  )

  $path = Get-DeepMemoryPath -Path $Path
  if (-not (Test-Path -LiteralPath $path)) { return @() }

  $tokens   = Parse-QueryTokens -Query $Query
  $qTags    = @($tokens | Where-Object { $_.StartsWith('#') } | ForEach-Object { $_.Substring(1).ToLowerInvariant() })
  $qSources = @($tokens | Where-Object { $_.StartsWith('@') } | ForEach-Object { $_.Substring(1).ToLowerInvariant() })
  $qWords   = @($tokens | Where-Object { -not ($_.StartsWith('#') -or $_.StartsWith('@')) })

  if ($Tags)    { $qTags    += ($Tags    | ForEach-Object { $_.ToLowerInvariant() }) }
  if ($Sources) { $qSources += ($Sources | ForEach-Object { $_.ToLowerInvariant() }) }
  $qTags    = $qTags    | Select-Object -Unique
  $qSources = $qSources | Select-Object -Unique

  $sr = Open-SharedReader -Path $path
  $results = New-Object System.Collections.Generic.List[object]
  $lineNo = 0

  try {
    foreach ($rec in (ConvertFrom-JsonL -Reader $sr)) {
      $o = $rec.__obj
      $oTs = $null; try { $oTs = [datetime]$o.ts } catch { }

      if ($After  -and $oTs -and $oTs -lt $After)  { $lineNo++; continue }
      if ($Before -and $oTs -and $oTs -gt $Before) { $lineNo++; continue }

      $tags    = Normalize-Tags $o.tags
      $source  = ("$($o.source)").ToLowerInvariant()
      $content = ("$($o.content)")

      if ($qSources.Count -gt 0 -and (-not $qSources.Contains($source))) { $lineNo++; continue }
      if ($qTags.Count -gt 0) {
        $missing = @($qTags | Where-Object { $tags -notcontains $_ })
        if ($missing.Count -gt 0) { $lineNo++; continue }
      }

      $score = 0.0
      foreach ($w in $qWords) {
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        if ($content.IndexOf($w, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $score += 2.0 }
        if ($w -match '\s' -and ($content -match [regex]::Escape($w))) { $score += 3.0 }
      }
      foreach ($t in $qTags) { if ($tags -contains $t) { $score += 4.0 } }
      if ($qSources.Count -gt 0 -and $qSources.Contains($source)) { $score += 1.0 }

      if ($oTs) {
        $days = [math]::Min(90.0, [math]::Max(0.0, ((Get-Date) - $oTs).TotalDays))
        $score *= (1.0 + (1.0 - ($days / 90.0)) * 0.5)
      }

      if ($score -le 0 -and ($qWords.Count -gt 0 -or $qTags.Count -gt 0 -or $qSources.Count -gt 0)) { $lineNo++; continue }

      $snippet = $null
      if ($IncludeContent) {
        $snippet = if ($content.Length -le 220) { $content } else { $content.Substring(0, 220) + '…' }
      } else {
        $hit = $null
        foreach ($w in $qWords) {
          $idx = $content.IndexOf($w, [System.StringComparison]::OrdinalIgnoreCase)
          if ($idx -ge 0) { $hit = @{ index = $idx; word = $w }; break }
        }
        if ($hit) {
          $start = [math]::Max(0, $hit.index - 90)
          $len   = [math]::Min(180, $content.Length - $start)
          $snippet = $content.Substring($start, $len)
          if ($start -gt 0) { $snippet = '…' + $snippet }
          if ($start + $len -lt $content.Length) { $snippet += '…' }
        }
      }

      $results.Add([pscustomobject]@{
        id     = (New-MemoryId -LineNo $lineNo)
        ts     = $o.ts
        tags   = $tags
        source = $o.source
        score  = [math]::Round($score, 3)
        snippet= $snippet
      })
      $lineNo++
    }
  } finally { $sr.Dispose() }

  return ,($results | Sort-Object score -Descending | Select-Object -First $Limit)
}

Export-ModuleMember -Function Search-DeepMemory, Get-DeepMemoryById

