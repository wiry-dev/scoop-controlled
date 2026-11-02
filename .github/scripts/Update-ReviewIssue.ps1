<#
.SYNOPSIS
Keeps one GitHub issue listing what needs a decision after an update run.

.DESCRIPTION
Lists manifests held by a lock (from their metadata) and manifests whose upstream has complex changes
(from the Update-Bucket.ps1 log). The issue is created when there is something to review, updated
on each run, and closed when nothing is left. Frozen manifests are counted but not listed: they are
held deliberately. Needs GH_TOKEN with issues: write.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$LogPath,
    [string]$RunUrl = '',
    [string]$BucketPath = (Join-Path $PSScriptRoot '../../bucket'),
    [string]$Title = 'Update review: locks and complex changes'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../ManifestMetadata.ps1')

$lockStates = 'domain-change-lock', 'license-change-lock', 'version-check-lock', 'missing-source-lock'
$locked = @()
$frozenCount = 0
foreach ($file in Get-ChildItem -Path $BucketPath -Filter '*.json' -File) {
    $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $state = ''
    foreach ($line in @($json.'##')) {
        if (Test-MetadataLine $line) {
            $entry = ConvertFrom-MetadataLine $line
            if ($entry -and $entry.Key -eq 'sourceState') { $state = $entry.Value }
        }
    }
    if ($state -in $lockStates) { $locked += [pscustomobject]@{ Name = $file.BaseName; State = $state } }
    elseif ($state -eq 'frozen') { $frozenCount++ }
}

$complex = @(Select-String -LiteralPath $LogPath -Pattern 'Manifest (\S+)\.json has complex changes; manual review required' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)

$existing = gh issue list --repo $Repository --state open --search "in:title `"$Title`"" --json 'number,title' |
    ConvertFrom-Json | Where-Object { $_.title -eq $Title } | Select-Object -First 1

if ($locked.Count -eq 0 -and $complex.Count -eq 0) {
    if ($existing) {
        gh issue close $existing.number --repo $Repository --comment "Nothing left to review as of $RunUrl"
    }
    Write-Host 'Nothing to review'
    return
}

$body = [System.Text.StringBuilder]::new()
[void]$body.AppendLine('Manifests that the scheduled update left for a decision. Review them locally with `.\Update-Bucket.ps1 -ProcessLocks` (locks) or `-Interactive` (complex changes), then push.')
[void]$body.AppendLine()
if ($RunUrl) { [void]$body.AppendLine("Last updated by $RunUrl, where the log has the diffs.").AppendLine() }
if ($locked.Count -gt 0) {
    [void]$body.AppendLine("### Locked ($($locked.Count))").AppendLine().AppendLine('| Manifest | Lock |').AppendLine('|---|---|')
    foreach ($l in $locked | Sort-Object State, Name) { [void]$body.AppendLine("| ``$($l.Name)`` | ``$($l.State)`` |") }
    [void]$body.AppendLine()
}
if ($complex.Count -gt 0) {
    [void]$body.AppendLine("### Complex changes upstream ($($complex.Count))").AppendLine()
    foreach ($c in $complex) { [void]$body.AppendLine("- ``$c``") }
    [void]$body.AppendLine()
}
[void]$body.AppendLine("$frozenCount manifest(s) are frozen and not listed.")

$bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "issue-$([guid]::NewGuid()).md"
try {
    $body.ToString() | Set-Content -Path $bodyFile -Encoding utf8NoBOM
    if ($existing) { gh issue edit $existing.number --repo $Repository --body-file $bodyFile }
    else { gh issue create --repo $Repository --title $Title --body-file $bodyFile }
    if ($LASTEXITCODE -ne 0) { throw "gh failed (exit code $LASTEXITCODE)" }
}
finally {
    Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
}
Write-Host "Review issue lists $($locked.Count) locked and $($complex.Count) complex"
