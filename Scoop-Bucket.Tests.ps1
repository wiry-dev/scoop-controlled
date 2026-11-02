#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }
# Bucket tests: PowerShell syntax of the repository's scripts and schema validation of the manifests.
# Scoop's own Import-Bucket-Tests.ps1 is not used: its style rules require CRLF everywhere, which conflicts
# with this repository's .gitattributes (LF for JSON, YAML, Markdown and shell scripts), and its CI mode
# fails on a commit with no parent.
# In CI only manifests changed by the latest commit are validated (all of them on a root commit); locally, all are.

BeforeDiscovery {
    $repoRoot = $PSScriptRoot
    $bucketDir = Join-Path $repoRoot 'bucket'

    $psFiles = @(Get-ChildItem -Path $repoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object { $_.FullName })

    $manifestFiles = @(Get-ChildItem -Path $bucketDir -Filter '*.json' -File | ForEach-Object { $_.FullName })
    if ($env:CI -eq 'true') {
        git -C $repoRoot rev-parse --verify --quiet 'HEAD^' *> $null
        if ($LASTEXITCODE -eq 0) {
            $manifestFiles = @(git -C $repoRoot diff --name-only --diff-filter=d 'HEAD^' HEAD -- 'bucket/*.json' |
                ForEach-Object { Join-Path $repoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ })
        }
    }
}

Describe 'PowerShell scripts' {
    It '<_> has no syntax errors' -TestCases $psFiles {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$null, [ref]$errors)
        ($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'Manifest validates against the schema' {
    BeforeAll {
        if (-not $env:SCOOP_HOME) { $env:SCOOP_HOME = Resolve-Path (scoop prefix scoop) }
        Add-Type -Path "$env:SCOOP_HOME/supporting/validator/bin/Scoop.Validator.dll"
        $validator = New-Object Scoop.Validator("$env:SCOOP_HOME/schema.json", $true)
    }
    if ($manifestFiles.Count -gt 0) {
        It '<_>' -TestCases $manifestFiles {
            $file = $_
            $validator.Validate($file)
            if ($validator.Errors.Count -gt 0) {
                Write-Host "  [-] $file has $($validator.Errors.Count) error(s)" -ForegroundColor Red
                Write-Host $validator.ErrorsAsString -ForegroundColor Yellow
            }
            $validator.Errors.Count | Should -Be 0
        }
    }
}
