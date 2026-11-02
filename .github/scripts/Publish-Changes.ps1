<#
.SYNOPSIS
Commits the working tree's changes through the GitHub API, so that the commit is signed by GitHub.

.DESCRIPTION
A 'git push' from a runner produces an unsigned commit. The GraphQL createCommitOnBranch mutation
instead creates the commit on GitHub's side, signed and shown as Verified. File contents are taken
from the git index (after 'git add'), so .gitattributes line-ending rules are applied as for a normal commit.
The commit is rejected if the branch has moved since checkout (expectedHeadOid).
Needs GH_TOKEN with contents: write. Writes 'committed=true|false' to GITHUB_OUTPUT when run in Actions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,   # owner/name
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$Headline,
    [string]$Body = '',
    [string]$Path = 'bucket'
)
$ErrorActionPreference = 'Stop'

function Get-IndexBlobBase64([string]$RepoPath) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in 'cat-file', 'blob', ":$RepoPath") { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    $buffer = [System.IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($buffer)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "git cat-file failed for '$RepoPath'" }
    return [Convert]::ToBase64String($buffer.ToArray())
}

function Set-Output([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
}

git add --all -- $Path
$changes = @(git diff --cached --name-status --no-renames -- $Path)
if ($changes.Count -eq 0) {
    Write-Host 'No changes to commit'
    Set-Output 'committed' 'false'
    return
}

$additions = [System.Collections.Generic.List[object]]::new()
$deletions = [System.Collections.Generic.List[object]]::new()
foreach ($line in $changes) {
    $status, $file = $line -split "`t", 2
    if ($status -eq 'D') { $deletions.Add(@{ path = $file }) }
    else { $additions.Add(@{ path = $file; contents = (Get-IndexBlobBase64 $file) }) }
}

$request = @{
    query     = 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }'
    variables = @{
        input = @{
            branch          = @{ repositoryNameWithOwner = $Repository; branchName = $Branch }
            message         = @{ headline = $Headline; body = $Body }
            expectedHeadOid = (git rev-parse HEAD)
            fileChanges     = @{ additions = $additions; deletions = $deletions }
        }
    }
}
$requestFile = Join-Path ([System.IO.Path]::GetTempPath()) "commit-$([guid]::NewGuid()).json"
try {
    $request | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $requestFile -Encoding utf8NoBOM
    $response = gh api graphql --input $requestFile | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $response.errors) { throw "Commit failed: $($response.errors | ConvertTo-Json -Depth 5)" }
}
finally {
    Remove-Item -LiteralPath $requestFile -ErrorAction SilentlyContinue
}
$commit = $response.data.createCommitOnBranch.commit
Write-Host "Committed $($changes.Count) file(s): $($commit.url)"
Set-Output 'committed' 'true'
