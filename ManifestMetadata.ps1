# Shared settings and helpers for the custom metadata kept in each manifest's "##" comment block, and for locating
# the local clones of the upstream buckets. Dot-sourced by Update-Bucket.ps1, Add-Manifest.ps1 and Seed-ManifestSources.ps1.

# Prefix written in front of every metadata key (e.g. "__sourceState: active"). It marks our lines apart from
# upstream comments, so an upstream comment that happens to start with e.g. "source:" is never taken for metadata.
# Lines without the prefix (the older format) are still read, and are rewritten with the prefix on the next write;
# '.\Update-Bucket.ps1 -NormaliseMetadata' rewrites them all at once.
# Changing this later: lines written with the previous (non-empty) prefix are not recognised, so convert them first.
$MetadataPrefix = '__'

$MetadataKeys = @(
    'source', 'sourceUrl', 'sourceLastUpdated', 'sourceLastChangeFound', 'sourceState', 'sourceDelayDays',
    'sourceUpdateMinimumDays', 'sourceDeferredUpdateFound', 'sourceComment', 'sourceNotes', 'sourceHash', 'sourceLicenceOpen'
)

# Environment variable holding the folder that contains the local clones of the upstream buckets listed in
# local-repos.cfg. Manifest 'source' paths and local-repos.cfg entries are stored relative to it as
# %SCOOP_CONTROLLED_SOURCES%\..., so the repository works wherever each user keeps their clones.
$SourcesRootVariable = 'SCOOP_CONTROLLED_SOURCES'

# Matches a metadata line, with or without the prefix; group 1 is the key, group 2 the value
$MetadataLinePattern = "^(?:$([regex]::Escape($MetadataPrefix)))?($($MetadataKeys -join '|'))\s*:\s*(.*)$"

Function Get-SourcesRoot {
    $root = [Environment]::GetEnvironmentVariable($SourcesRootVariable)
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    return $root.Trim().TrimEnd('\', '/')
}

# Stops the script unless the sources root is set and exists; without it every source path would be unresolvable
# and manifests would wrongly be treated as having lost their upstream.
Function Assert-SourcesRoot {
    $root = Get-SourcesRoot
    if (-not $root) {
        throw "Environment variable '$SourcesRootVariable' is not set. Set it to the folder holding your clones of the upstream buckets, e.g. [Environment]::SetEnvironmentVariable('$SourcesRootVariable', 'D:\src\scoop-sources', 'User')"
    }
    if (-not (Test-Path -Path $root -PathType Container)) {
        throw "'$SourcesRootVariable' points at '$root', which does not exist."
    }
}

# '%SCOOP_CONTROLLED_SOURCES%\scoop-main\...' -> 'D:\src\scoop-sources\scoop-main\...'
Function Expand-SourcePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

# 'D:\src\scoop-sources\scoop-main\...' -> '%SCOOP_CONTROLLED_SOURCES%\scoop-main\...' (other values are left as they are)
Function Compress-SourcePath {
    param([string]$Path)
    $root = Get-SourcesRoot
    if (-not $root -or [string]::IsNullOrWhiteSpace($Path)) { return $Path }
    foreach ($separator in '\', '/') {
        $prefix = $root + $separator
        if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "%$SourcesRootVariable%$separator" + $Path.Substring($prefix.Length)
        }
    }
    return $Path
}

Function Test-MetadataLine {
    param([string]$Line)
    return $Line -match $MetadataLinePattern
}

# Returns @{ Key; Value } for a metadata line, or $null for any other comment line. 'source' paths are expanded.
Function ConvertFrom-MetadataLine {
    param([string]$Line)
    $match = [regex]::Match([string]$Line, $MetadataLinePattern)
    if (-not $match.Success) { return $null }
    $key = $match.Groups[1].Value
    $value = $match.Groups[2].Value.Trim()
    if ($key -eq 'source') { $value = Expand-SourcePath -Path $value }
    return [pscustomobject]@{ Key = $key; Value = $value }
}

# Formats a metadata line with the prefix; 'source' paths under the sources root are stored relative to it.
Function ConvertTo-MetadataLine {
    param([string]$Key, $Value)
    if ($Key -eq 'source') { $Value = Compress-SourcePath -Path ([string]$Value) }
    return "$MetadataPrefix$($Key): $Value"
}

# True if the line is metadata but not in the current canonical form (missing prefix, absolute source path, ...)
Function Test-MetadataLineNeedsRewrite {
    param([string]$Line)
    $entry = ConvertFrom-MetadataLine -Line $Line
    if (-not $entry) { return $false }
    return (ConvertTo-MetadataLine -Key $entry.Key -Value $entry.Value) -cne $Line
}

# Reads local-repos.cfg ('<local path>;<git remote>' per line; blank lines and '#' comments ignored).
# Paths may use %SCOOP_CONTROLLED_SOURCES% (or any environment variable) and may be relative to $BaseDir.
Function Get-LocalRepoEntries {
    param([string]$ConfigPath, [string]$BaseDir)
    if (-not (Test-Path -Path $ConfigPath)) { return @() }
    $entries = @()
    foreach ($line in Get-Content -Path $ConfigPath) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed -notmatch ';') { continue }
        $parts = $trimmed -split ';', 2
        $path = Expand-SourcePath -Path $parts[0].Trim()
        if ($BaseDir -and -not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path -Path $BaseDir -ChildPath $path }
        $entries += [pscustomobject]@{ Path = $path; ConfiguredPath = $parts[0].Trim(); Url = $parts[1].Trim() }
    }
    return $entries
}
