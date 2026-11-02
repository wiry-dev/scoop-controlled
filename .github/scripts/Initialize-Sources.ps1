<#
.SYNOPSIS
Clones the upstream buckets listed in local-repos.cfg for a CI run.

.DESCRIPTION
Clones over HTTPS (the configured SSH remotes need keys a runner doesn't have) and blobless
(--filter=blob:none): full commit and tree history is kept, so Update-Bucket.ps1 can still date
upstream changes with 'git log', while file contents are only fetched when read.
SCOOP_CONTROLLED_SOURCES must be set to the folder to clone into.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../../local-repos.cfg')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../ManifestMetadata.ps1')
$root = Get-SourcesRoot
if ($root) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
Assert-SourcesRoot

foreach ($entry in Get-LocalRepoEntries -ConfigPath $ConfigPath) {
    $url = $entry.Url -replace '^git@github\.com:', 'https://github.com/'
    if (Test-Path -LiteralPath (Join-Path $entry.Path '.git')) {
        Write-Host "Updating $($entry.Path)"
        git -C $entry.Path pull --quiet
    }
    else {
        Write-Host "Cloning $url -> $($entry.Path)"
        git clone --quiet --filter=blob:none $url $entry.Path
    }
    if ($LASTEXITCODE -ne 0) { throw "git failed for '$url' (exit code $LASTEXITCODE)" }
}
