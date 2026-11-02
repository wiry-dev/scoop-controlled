<#
.SYNOPSIS
  Checks for and applies updates for Scoop manifests, with advanced change tracking and an interactive mode.

.DESCRIPTION
  This script tracks changes using metadata stored within the schema-conformant "##" property.
    It respects the 'sourceState' metadata field ('active', 'frozen', 'dead', 'manual', and explicit lock states) to control update behavior.
  It also supports 'sourceDelayDays' to delay updates, 'sourceUpdateMinimumDays' to throttle update frequency,
  a 'sourceDeferredUpdateFound' field to track deferred updates, and a 'sourceComment' field for arbitrary user notes.

    The script can run in seven modes:
    1. Default (Automatic): Auto-applies simple updates and flags complex changes.
    2. Interactive Mode: Prompts the user to accept or skip complex changes.
    3. List Pending Mode: Lists manifests with pending changes and their relevant timestamps.
    4. List Manual Mode: Lists all manifests configured as MANUAL.
    5. List Locks Mode: Lists manifests that are frozen or in a lock state (domain-change-lock, license-change-lock, version-check-lock).
    6. Process Locks Mode: Interactively reviews locked manifests and allows unlocking with updates.
    7. Verbose List Mode: When used with -ListPending, shows all non-manual files and explains their status.
    8. Normalise Metadata Mode: Sets 'sourceLicenceOpen' from each licence and adds the metadata prefix to older lines.

  Prompts show the action taken when Enter is pressed: accept for domain/version locks and complex changes,
  skip (leave frozen) for frozen packages, and freeze (then prompt for a comment) where the licence changes.
  Licence changes between open licences (see 'sourceLicenceOpen') are not treated as a concern, and GitHub
  hosts (api.github.com, raw.githubusercontent.com, {owner}.github.io for a repo owner used, etc.) are treated
  as the same domain. Locks whose condition no longer applies are released during automatic runs.

.PARAMETER BucketPath
  The path to the 'bucket' directory to process. Defaults to the 'bucket' folder next to this script.

.PARAMETER ListPending
  Lists all manifests with detected changes that have not yet been applied.

.PARAMETER ListManual
  Lists all manifests that are configured with a source of 'MANUAL' or a state of 'manual'.

.PARAMETER ListLocks
  Lists all manifests that are configured with a lock state such as 'frozen', 'domain-change-lock', 'license-change-lock', or 'version-check-lock'.

.PARAMETER ProcessLocks
  Interactively processes locked manifests (frozen or explicit lock states) and allows unlocking with updates.

.PARAMETER NormaliseMetadata
  Sets the 'sourceLicenceOpen' metadata flag (true for Apache, MIT, GPL/LGPL/AGPL, Eclipse or BSD licences) on all
  manifests in scope, and rewrites metadata lines into the current form: with the metadata prefix, and with 'source'
  paths under %SCOOP_CONTROLLED_SOURCES% stored relative to it (see ManifestMetadata.ps1).
  Both are also kept up to date whenever a manifest is written. Alias: -SetLicenceFlags.

.PARAMETER ExcludeFrozen
  When used with -ProcessLocks or -Interactive, ignores manifests with a 'frozen' state.

.PARAMETER Interactive
  Starts an interactive session to review and apply pending complex changes one by one.

.PARAMETER VerboseList
  When used with -ListPending, outputs status for all non-pending manifests as well.

.PARAMETER VerboseProcessing
  More detailed output during processing in all modes including the pre-processing steps common to all.

.PARAMETER Trace
  Trace mode, the maximum level of logged output detail.

.PARAMETER ChangesOnly
  In the default automatic mode, only outputs information for manifests that have updates or changes.

.PARAMETER Scope
  Restricts the scope of the manifests to only those matching the provided regex name pattern

.PARAMETER HideSkipped
  Under verbose processing, will nevertheless hide manifests that are skipped due to scope filtering.

.PARAMETER SkipFrozen
  In the default automatic mode, prevents showing the diff for frozen packages that have updates.

.PARAMETER AutoComplex
  In the default automatic mode, logs complex changes, dumps the diff, and still applies the changes.

.PARAMETER InteractiveComplex
  In the default automatic mode, prompts for whether to accept complex changes instead of auto-applying.

.PARAMETER DefaultDelayDays
  Default number of days to delay updates when sourceDelayDays is not explicitly set in a manifest.

.PARAMETER DefaultMinimumDays
  Default minimum number of days between updates when sourceUpdateMinimumDays is not explicitly set in a manifest.

.PARAMETER DeepComparison
  Determines whether to compare all JSON fields (except the '##' comment node) to decide if an update is needed.

.PARAMETER FullUpdate
  Forces a full update run: ignores delay/minimum-day windows, auto-accepts complex changes,
  and enables deep comparison to detect any JSON changes (excluding the '##' comment node).

.PARAMETER PullSources
  Pulls each repository listed in local-repos.cfg before processing any manifests, cloning any that are missing.

.EXAMPLE
  # Runs automatically to check for and apply updates in the default bucket path without user interaction.
  .\Update-Bucket.ps1

.EXAMPLE
  # Lists all the pending changes to be made and verbosely outputs the status of all manifests assessed.
  .\Update-Bucket.ps1 -ListPending -VerboseProcessing

.EXAMPLE
  # Interactively processes only the manifests beginning with characters 'ag' or 'bi'; all others have processing skipped.
  .\Update-Bucket.ps1 -Interactive -VerboseProcessing -HideSkipped -Scope '^(ag|bi).*'

.EXAMPLE
  # Trace mode with extra timing detail on interactively processing only the manifests beginning with characters 'ag' or 'bi'; all others have processing skipped.
  .\Update-Bucket.ps1 -Interactive -VerboseProcessing -HideSkipped -Trace -Scope '^(ag|bi).*'

.EXAMPLE
  # Fully updates all non-locked active manifests, including re-pulling all local source repositories.
  .\Update-Bucket.ps1 -FullUpdate

.EXAMPLE
  # Interactively processes all locked manifests, excluding those that are frozen.
  .\Update-Bucket.ps1 -ProcessLocks -ExcludeFrozen

#>
[CmdletBinding(DefaultParameterSetName = 'Automatic')]
param(
    [Parameter()]
    [string]$BucketPath = $null,

    [Parameter(ParameterSetName = 'ListPending')]
    [switch]$ListPending,

    [Parameter(ParameterSetName = 'ListManual')]
    [switch]$ListManual,

    [Parameter(ParameterSetName = 'ListLocks')]
    [switch]$ListLocks,

    [Parameter(ParameterSetName = 'ProcessLocks')]
    [switch]$ProcessLocks,

    [Parameter(ParameterSetName = 'NormaliseMetadata')]
    [Alias('SetLicenceFlags')]
    [switch]$NormaliseMetadata,

    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    [Parameter(ParameterSetName = 'ListPending')]
    [switch]$VerboseList,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$ChangesOnly,

    [Parameter()]
    [switch]$VerboseProcessing,

    [Parameter()]
    [switch]$Trace,

    [Parameter()]
    [string]$Scope = '.*',

    [Parameter()]
    [switch]$HideSkipped,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$SkipFrozen,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$AutoComplex,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$InteractiveComplex,

    [Parameter()]
    [int]$DefaultDelayDays = 7,

    [Parameter()]
    [int]$DefaultMinimumDays = 2,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$DeepComparison,

    [Parameter(ParameterSetName = 'Automatic')]
    [switch]$FullUpdate,

    [Parameter()]
    [switch]$PullSources,

    [Parameter()]
    [switch]$ExcludeFrozen
)

# --- Initial Setup ---
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($BucketPath)) {
    $BucketPath = Join-Path -Path $scriptDir -ChildPath 'bucket'
}
if (-Not (Test-Path -Path $BucketPath)) {
    throw "Bucket path not found: '$BucketPath'"
}

# =================================================================================
# Global Defaults
# =================================================================================

# Metadata key list, line prefix ($MetadataPrefix) and sources root variable are shared with the other scripts
. (Join-Path -Path $PSScriptRoot -ChildPath 'ManifestMetadata.ps1')

# Every mode except metadata normalisation reads the local upstream clones
if (-Not $NormaliseMetadata) {
    Assert-SourcesRoot
}
$timestampFormat = "yyMMdd HH:mm:ss"
$logTimestamp = $true

# =================================================================================
# Helper Functions
# =================================================================================

Function Write-Log {
    param(
        [string]$Message,
        [String]$Colour = "DarkGray"
    )
    if ($logTimestamp) {
        Write-Host "$(Get-Date -Format $timestampFormat) - $Message" -ForegroundColor $Colour
    }
    else {
        Write-Host "$Message" -ForegroundColor $Colour
    }
}

Function Write-LogWarning {
    param(
        [string]$Message,
        [String]$Colour = "DarkRed"
    )
    if ($logTimestamp) {
        Write-Warning "$(Get-Date -format o) - $Message"
    }
    else {
        Write-Warning "$Message"
    }
}

Function Write-LogHighlight {
    param([string]$Message)
    Write-Log -Message $Message -Colour Yellow
}

Function Write-LogAttention {
    param([string]$Message)
    Write-Log -Message $Message -Colour Cyan
}

Function Write-LogConcern {
    param([string]$Message)
    Write-Log -Message $Message -Colour Magenta
}


Function Write-LogVerbose {
    param([string]$Message)
    if ($VerboseProcessing) {
        Write-Log -Message $Message -Colour DarkYellow
    }
}

Function Write-LogTrace {
    param([string]$Message)
    if ($Trace) {
        Write-Log -Message $Message -Colour Blue
    }
}

Function Invoke-PullSourceRepos {
    param(
        [string]$ConfigPath,
        [switch]$VerboseOutput
    )

    if (-Not (Test-Path $ConfigPath)) {
        Write-LogWarning "local-repos.cfg not found at '$ConfigPath'. Skipping source pulls"
        return
    }

    $entries = @(Get-LocalRepoEntries -ConfigPath $ConfigPath -BaseDir $scriptDir)
    if ($entries.Count -eq 0) {
        Write-LogWarning "No repository entries found in '$ConfigPath'. Skipping source pulls"
        return
    }

    Write-Log "Pulling source repositories listed in '$ConfigPath'..."
    foreach ($entry in $entries) {
        $repoPath = $entry.Path
        if ([string]::IsNullOrWhiteSpace($repoPath)) { continue }

        # Clone anything not present yet, under the name local-repos.cfg gives it
        if (-Not (Test-Path $repoPath)) {
            if ([string]::IsNullOrWhiteSpace($entry.Url)) {
                Write-LogWarning "Source repo path not found and no remote configured: '$repoPath'"
                continue
            }
            Write-Log "  -> Cloning '$($entry.Url)' into '$repoPath'"
            git clone $entry.Url $repoPath | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-LogWarning "Clone failed for '$($entry.Url)' (exit code $LASTEXITCODE)" }
            continue
        }

        if (-Not (Test-Path (Join-Path $repoPath '.git'))) {
            Write-LogWarning "Skipping non-git repo path: '$repoPath'"
            continue
        }

        try {
            if ($VerboseOutput) {
                Write-Log "  -> Pulling '$repoPath'"
            }
            git -C $repoPath pull | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-LogWarning "Pull failed for '$repoPath' (exit code $LASTEXITCODE)"
            }
            elseif ($VerboseOutput) {
                Write-Log "  Pulled '$repoPath'" "Green"
            }
        }
        catch {
            Write-LogWarning "Pull failed for '$repoPath': $($_.Exception.Message)"
        }
    }
}

$ChoiceNames = @{ a = 'Accept'; f = 'Freeze'; s = 'Skip' }

# Prompts for a decision, showing which action pressing Enter will take, and re-prompts on unrecognised input.
Function Get-ChangeDecision {
    param(
        [string]$Prompt = "Apply this change? (A)ccept / (F)reeze / (S)kip / (Q)uit",
        [ValidateSet('a', 'f', 's')]
        [string]$Default = 'a',
        [string[]]$Allowed = @('a', 'f', 's', 'q')
    )
    while ($true) {
        $choice = Read-Host "$Prompt [Enter = $($ChoiceNames[$Default])]"
        if ([string]::IsNullOrWhiteSpace($choice)) { return $Default }
        $choice = $choice.Trim().ToLower()
        if ($choice -in $Allowed) { return $choice }
        Write-LogWarning "  Unrecognised choice '$choice'; please choose one of: $($Allowed -join ', ')"
    }
}

Function Invoke-ChangeDecision {
    param(
        [string]$Choice,
        [pscustomobject]$Data,
        [pscustomobject]$RemoteJson,
        [string]$RunTimestamp,
        [pscustomobject]$SourceInfo,
        [switch]$RecordDeferredOnSkipOrFreeze
    )

    if (-Not $SourceInfo) {
        $SourceInfo = Get-GitCommitDate -FilePath $Data.Metadata.source -StoredHash $Data.Metadata.sourceHash -StoredDate $Data.Metadata.sourceLastUpdated
    }

    switch ($Choice) {
        'a' {
            $newMetadata = $Data.Metadata.Clone()
            $newMetadata.sourceLastUpdated = $SourceInfo.Date
            $newMetadata.sourceHash = $SourceInfo.Hash
            $newMetadata.sourceLastChangeFound = $RunTimestamp
            if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
                $newMetadata.Remove('sourceDeferredUpdateFound')
            }
            $newJson = Set-CustomMetadata -JSONObject $RemoteJson -MetadataToWrite $newMetadata
            Write-Log "    -> Writing accepted changes to '$($Data.File.Name)'..."
            Write-Manifest -MetadataToWrite $newJson -FilePath $Data.File.FullName
            Write-Log "  Accepted. Manifest '$($Data.File.Name)' has been updated" Green
            return $true
        }
        'f' {
            Write-Log "  -> Freezing package '$($Data.File.Name)' at current version"
            $newMetadata = $Data.Metadata.Clone()
            $newMetadata.sourceState = 'frozen'
            $newMetadata.sourceLastUpdated = $SourceInfo.Date
            $newMetadata.sourceHash = $SourceInfo.Hash
            $newMetadata.sourceLastChangeFound = $RunTimestamp
            if ($RecordDeferredOnSkipOrFreeze) {
                $newMetadata.sourceDeferredUpdateFound = $RunTimestamp
            }
            $updatedJson = Set-CustomMetadata -JSONObject $Data.Local -MetadataToWrite $newMetadata
            Write-Log "    -> Writing updated state to manifest..."
            Write-Manifest -MetadataToWrite $updatedJson -FilePath $Data.File.FullName
            return $true
        }
        's' {
            Write-Log "  Skipped '$($Data.File.Name)'"
            if ($RecordDeferredOnSkipOrFreeze) {
                Set-DeferredUpdateFound -Data $Data -RunTimestamp $RunTimestamp | Out-Null
            }
            return $true
        }
        'q' {
            Write-Log "Aborting update run"
            return $false
        }
        default {
            Write-Log "  Invalid choice. Skipping '$($Data.File.Name)'"
            return $true
        }
    }
}

# Returns the formatted date in our default global format. Takes an input DateTime otherwise defaults to `now` in UTC
Function Get-FormattedDate {
    param([datetime]$DateTime = ([datetime]::UtcNow))
    return $DateTime.ToString($timestampFormat)
}

# A helper to get 'now' in the context of operation. Currently in UTC but provides a shim to change this in the future if needed.
Function Get-Now {
    return [datetime]::UtcNow
}

Function Get-DeferredUpdateDate {
    param([hashtable]$Metadata)

    if (-Not $Metadata -Or -Not $Metadata.sourceDeferredUpdateFound) { return $null }
    try {
        return [datetime]::ParseExact($Metadata.sourceDeferredUpdateFound, $timestampFormat, $null)
    }
    catch {
        return $null
    }
}

Function Set-DeferredUpdateFound {
    param(
        [pscustomobject]$Data,
        [string]$RunTimestamp
    )

    if ($Data.Metadata.sourceDeferredUpdateFound) { return $false }
    $newMetadata = $Data.Metadata.Clone()
    $newMetadata.sourceDeferredUpdateFound = $RunTimestamp
    $updatedJson = Set-CustomMetadata -JSONObject $Data.Local -MetadataToWrite $newMetadata
    Write-Log "      -> Recording deferred update timestamp in '$($Data.File.Name)'"
    Write-Manifest -MetadataToWrite $updatedJson -FilePath $Data.File.FullName
    return $true
}

Function Get-GitCommitDate {
    param([string]$FilePath, [string]$StoredHash, [string]$StoredDate)
    if (-Not (Test-Path $FilePath)) { return $null }
    $dir = Split-Path $FilePath
    $repoDir = $dir
    while ($repoDir -And !(Test-Path (Join-Path $repoDir ".git"))) {
        $parent = Split-Path $repoDir
        if ($parent -eq $repoDir) { $repoDir = $null; break }
        $repoDir = $parent
    }
    if ($repoDir) {
        $repoRelativePath = $FilePath.Replace($repoDir, "").TrimStart("\").Replace("\", "/")

        # Resolve the current blob hash (instant metadata lookup)
        $currentHash = git -C $repoDir rev-parse "HEAD:$repoRelativePath" 2>$null

        # If we have a hash and it matches the stored one, skip the slow history walk
        if ($currentHash -And $StoredHash -And ($currentHash -eq $StoredHash) -And $StoredDate) {
            Write-LogTrace "      -> Hash matches stored value ($currentHash); skipping slow git walk"
            return [pscustomobject]@{ Date = $StoredDate; Hash = $currentHash; Match = $true }
        }

        Write-LogTrace "      -> Hash changed or missing. Getting last commit date for '$FilePath'"
        $gitDate = git -C $repoDir --no-pager log -1 --format=%cI -- $FilePath 2>$null
        Write-LogTrace "      -> Git last commit date for file '$FilePath' is '$gitDate'"
        if ($gitDate) {
            $finalDate = ([datetime]$gitDate).ToUniversalTime().ToString($timestampFormat)
        }
        else {
            $finalDate = (Get-Item $FilePath).LastWriteTime.ToUniversalTime().ToString($timestampFormat)
        }
        return [pscustomobject]@{ Date = $finalDate; Hash = $currentHash; Match = $false }
    }
    return [pscustomobject]@{ Date = (Get-Item $FilePath).LastWriteTime.ToUniversalTime().ToString($timestampFormat); Hash = "LWT"; Match = $false }
}

Function Get-RepoRootFromPath {
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $null }
    $dir = Split-Path -Path $FilePath -Parent
    if (-not $dir) { return $null }
    $repoDir = $dir
    while ($repoDir -and -not (Test-Path (Join-Path $repoDir ".git"))) {
        $parent = Split-Path $repoDir
        if ($parent -eq $repoDir) { $repoDir = $null; break }
        $repoDir = $parent
    }
    return $repoDir
}

Function Find-DeprecatedManifestPath {
    param([string]$SourcePath)
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { return $null }
    $repoRoot = Get-RepoRootFromPath -FilePath $SourcePath
    if (-not $repoRoot) { return $null }
    $fileName = Split-Path -Path $SourcePath -Leaf
    $candidates = @(
        (Join-Path $repoRoot "deprecated" $fileName),
        (Join-Path $repoRoot "bucket" "deprecated" $fileName)
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -Path $candidate) { return $candidate }
    }
    return $null
}

Function Set-SourceComment {
    param(
        [hashtable]$Metadata,
        [string]$Comment
    )
    if ([string]::IsNullOrWhiteSpace($Comment)) { return }
    $existing = $Metadata.sourceComment
    if ([string]::IsNullOrWhiteSpace($existing)) {
        $Metadata.sourceComment = $Comment
    }
    elseif ($existing -notmatch [regex]::Escape($Comment)) {
        $Metadata.sourceComment = "$existing; $Comment"
    }
}

Function Set-SourceNotesIfMissing {
    param([hashtable]$Metadata)
    if (-not $Metadata.ContainsKey('sourceNotes')) {
        $Metadata.sourceNotes = ''
    }
}

Function Resolve-MissingSource {
    param(
        [pscustomobject]$Data,
        [string]$RunTimestamp
    )

    $deprecatedPath = Find-DeprecatedManifestPath -SourcePath $Data.Metadata.source
    # Already recorded: rewriting would only append another dated comment on every run
    $targetState = if ($deprecatedPath) { 'deprecated' } else { 'missing-source-lock' }
    if ($Data.Metadata.sourceState -eq $targetState) {
        Write-LogVerbose "    -> '$($Data.File.Name)' is already marked '$targetState'"
        return $false
    }
    $newMetadata = $Data.Metadata.Clone()
    $newMetadata.sourceLastChangeFound = $RunTimestamp

    if ($deprecatedPath) {
        $newMetadata.sourceState = 'deprecated'
        Set-SourceComment -Metadata $newMetadata -Comment "Deprecated (found in deprecated folder) on $RunTimestamp"
        Set-SourceNotesIfMissing -Metadata $newMetadata
        $updatedJson = Set-CustomMetadata -JSONObject $Data.Local -MetadataToWrite $newMetadata
        Write-Log "    -> Marking '$($Data.File.Name)' as deprecated (found in deprecated folder)"
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $Data.File.FullName
        return $true
    }

    $newMetadata.sourceState = 'missing-source-lock'
    Set-SourceComment -Metadata $newMetadata -Comment "Source missing; not found in source or deprecated folder as of $RunTimestamp"
    Set-SourceNotesIfMissing -Metadata $newMetadata
    $updatedJson = Set-CustomMetadata -JSONObject $Data.Local -MetadataToWrite $newMetadata
    Write-Log "    -> Marking '$($Data.File.Name)' as missing-source-lock"
    Write-Manifest -MetadataToWrite $updatedJson -FilePath $Data.File.FullName
    return $true
}

Function Get-CustomMetadata($JSONObject) {
    $metadata = @{}
    if ($JSONObject.PSObject.Properties['##']) {
        foreach ($line in $JSONObject.'##') {
            $entry = ConvertFrom-MetadataLine -Line $line
            if ($entry) { $metadata[$entry.Key] = $entry.Value }
        }
    }
    return $metadata
}

# Sets the custom metadata fields in the '##' property of the given JSON object.
# This is the only safe place we can modify in the manifest without breaking schema compliance.
# A little at risk of change by Scoop in the future but have to live with it.
Function Set-CustomMetadata($JSONObject, $MetadataToWrite) {
    if (-Not $JSONObject.PSObject.Properties['##']) {
        $JSONObject | Add-Member -MemberType NoteProperty -Name '##' -Value @()
    }
    elseif ($JSONObject.'##' -isnot [array]) {
        $JSONObject.'##' = @($JSONObject.'##')
    }
    $baseComments = @($JSONObject.'##' | Where-Object { -not (Test-MetadataLine -Line $_) })
    $metadataLines = @(
        $MetadataToWrite.GetEnumerator() |
        Sort-Object -Property Key |
        ForEach-Object { ConvertTo-MetadataLine -Key $_.Key -Value $_.Value }
    )
    $JSONObject.'##' = @($baseComments + $metadataLines)
    return $JSONObject
}

Function Get-RawManifestUrls {
    param([PsCustomObject]$Object)

    $urls = [System.Collections.Generic.List[string]]::new()
    $visited = [System.Collections.Generic.HashSet[int]]::new()

    $addUrlsFromString = {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        $pattern = '(?i)\b[a-z][a-z0-9+.-]*://[^\s"''<>`]+'
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            if ($match.Value) { $urls.Add($match.Value) }
        }
    }

    $walk = {
        param($value)
        if ($null -eq $value) { return }
        if ($value -is [string]) {
            & $addUrlsFromString $value
            return
        }
        if ($value -is [array]) {
            foreach ($item in $value) { & $walk $item }
            return
        }
        if ($value -is [hashtable] -or $value -is [psobject]) {
            $hash = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($value)
            if (-not $visited.Add($hash)) { return }
            foreach ($prop in $value.PSObject.Properties) {
                # '##' holds our own tracking metadata (e.g. sourceUrl), not download URLs
                if ($prop.Name -eq '##') { continue }
                & $walk $prop.Value
            }
        }
    }

    & $walk $Object

    return $urls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
}

Function Get-BaseUrlFromUrl {
    param([string]$Url)

    try {
        $uri = [Uri]::new($Url)
        $path = $uri.AbsolutePath
        $dir = Split-Path -Path $path -Parent
        if ([string]::IsNullOrWhiteSpace($dir) -or $dir -eq '.') { $dir = '/' }
        $dir = $dir.Replace('\', '/')
        if (-not $dir.StartsWith('/')) { $dir = '/' + $dir }
        return "{0}://{1}{2}" -f $uri.Scheme, $uri.Host, $dir.TrimEnd('/')
    }
    catch {
        return $null
    }
}

Function Get-ManifestBaseUrl {
    param([PsCustomObject]$Object)

    $candidateUrls = Get-RawManifestUrls -Object $Object
    foreach ($candidate in $candidateUrls) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate -match '\$') { continue }
        $baseUrl = Get-BaseUrlFromUrl -Url $candidate
        if ($baseUrl) { return $baseUrl }
    }
    return $null
}

Function Resolve-ManifestUrl {
    param(
        [string]$Url,
        [PsCustomObject]$Object
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }

    $resolvedUrl = $Url
    if ($Url -match '(\$\{?baseurl\}?|\$\{?url\}?)') {
        $baseUrl = Get-ManifestBaseUrl -Object $Object
        if ($baseUrl) {
            $resolvedUrl = $resolvedUrl.Replace('$baseurl', $baseUrl)
            $resolvedUrl = $resolvedUrl.Replace('${baseurl}', $baseUrl)
            $resolvedUrl = $resolvedUrl.Replace('$url', $baseUrl)
            $resolvedUrl = $resolvedUrl.Replace('${url}', $baseUrl)
        }
    }

    return $resolvedUrl
}

Function Get-ManifestUrls {
    param([PsCustomObject]$Object)

    $urls = Get-RawManifestUrls -Object $Object
    $resolvedUrls = @()
    foreach ($url in $urls) {
        $resolved = Resolve-ManifestUrl -Url $url -Object $Object
        if ($resolved) { $resolvedUrls += $resolved }
        if ($resolved -ne $url) { $resolvedUrls += $url }
    }

    return $resolvedUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
}

Function Get-ManifestUrlDomains {
    param([PsCustomObject]$Object)

    $urls = Get-ManifestUrls -Object $Object
    $domains = @()
    foreach ($url in $urls) {
        try {
            $uri = [Uri]::new($url)
            if ($uri.Host) { $domains += $uri.Host.ToLower() }
        }
        catch {
            continue
        }
    }
    return $domains | Sort-Object -Unique
}

Function Test-UrlDomainChange {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)

    $localUrls = Get-ManifestUrls -Object $LocalJson
    $remoteUrls = Get-ManifestUrls -Object $RemoteJson

    $getHost = {
        param($value)
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        try {
            $hostName = ([uri]$value).Host
            if (-not [string]::IsNullOrWhiteSpace($hostName)) { return $hostName.ToLower() }
        }
        catch { }
        if ($value -Match '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+)') { return $matches[1].ToLower() -replace '\\', '' }
        return $null
    }

    # Hosts that are all GitHub serving the same repositories
    $githubHosts = @('github.com', 'www.github.com', 'api.github.com', 'codeload.github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com')

    # Returns 'owner/repo' for GitHub URLs, or $null where no repository can be identified
    $getRepoId = {
        param($url)
        try {
            $uri = [uri]$url
            $hostName = $uri.Host.ToLower()
            if ($hostName -notin $githubHosts) { return $null }
            $segments = $uri.AbsolutePath.Trim('/').Split('/')
            if ($hostName -eq 'api.github.com') {
                # api.github.com/repos/{owner}/{repo}/... ; /repositories/{id}/... is opaque so can't be compared
                if ($segments.Length -ge 3 -and $segments[0] -ieq 'repos') {
                    return ($segments[1] + '/' + $segments[2]).ToLower()
                }
                return $null
            }
            if ($segments.Length -ge 2 -and $segments[0] -and $segments[1]) {
                return ($segments[0] + '/' + $segments[1]).ToLower()
            }
        }
        catch { }
        return $null
    }

    $localRepos = @($localUrls | ForEach-Object { & $getRepoId $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $remoteRepos = @($remoteUrls | ForEach-Object { & $getRepoId $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $githubOwners = @(($localRepos + $remoteRepos) | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)

    # GitHub hosts collapse to github.com, as do GitHub Pages sites ({owner}.github.io) of an owner whose repository the manifest uses
    $normaliseHost = {
        param($hostName)
        if ($hostName -in $githubHosts) { return 'github.com' }
        if ($hostName -match '^([a-z0-9-]+)\.github\.io$' -and $matches[1] -in $githubOwners) { return 'github.com' }
        return $hostName
    }

    $localDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($url in $localUrls) {
        $hostName = & $getHost $url
        if ($hostName) { [void]$localDomains.Add((& $normaliseHost $hostName)) }
    }

    $remoteDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($url in $remoteUrls) {
        $hostName = & $getHost $url
        if ($hostName) { [void]$remoteDomains.Add((& $normaliseHost $hostName)) }
    }

    # Check for domain changes
    if ($localDomains.Count -eq 0 -And $remoteDomains.Count -eq 0) {
        return $false
    }
    if (-Not $localDomains.SetEquals($remoteDomains)) {
        Write-LogTrace "      -> Domain sets differ: Local=($($localDomains -join ', ')) Remote=($($remoteDomains -join ', '))"
        return $true
    }

    # Same domains, but GitHub may now point at a different account/repo
    if ($localRepos.Count -gt 0 -and $remoteRepos.Count -gt 0) {
        $repoDiff = Compare-Object -ReferenceObject $localRepos -DifferenceObject $remoteRepos
        if ($null -ne $repoDiff) {
            Write-LogTrace "      -> GitHub repositories differ: Local=($($localRepos -join ', ')) Remote=($($remoteRepos -join ', '))"
            return $true
        }
    }

    return $false
}

# Returns the licence identifier from a manifest 'license' value (either a string or an object with 'identifier').
Function Get-LicenceIdentifier {
    param($License)
    if ($null -eq $License) { return $null }
    if ($License -is [string]) { return $License.Trim() }
    if ($License.PSObject.Properties['identifier']) { return ([string]$License.identifier).Trim() }
    return $null
}

# True when the licence identifier is an open licence: Apache, MIT, GPL (incl. LGPL/AGPL), Eclipse (EPL) or BSD.
# Comma-separated licences all apply, so every one must be open; '|' separates alternatives, so any one may be.
Function Test-IsOpenLicence {
    param([string]$Identifier)
    if ([string]::IsNullOrWhiteSpace($Identifier)) { return $false }
    $openPattern = '^(?i)(apache|mit|[la]?gpl|epl|eclipse|0?bsd)\b'
    $required = @($Identifier -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($required.Count -eq 0) { return $false }
    foreach ($part in $required) {
        $alternatives = @($part -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not ($alternatives | Where-Object { $_ -match $openPattern })) { return $false }
    }
    return $true
}

Function Get-LicenceOpenFlag {
    param([PsCustomObject]$Json)
    $license = $null
    if ($Json.PSObject.Properties['license']) { $license = $Json.license }
    if (Test-IsOpenLicence -Identifier (Get-LicenceIdentifier -License $license)) { return 'true' }
    return 'false'
}

# A licence change is only a concern when it could restrict use: moves between two open licences
# (or a changed licence URL on an unchanged open identifier) are not flagged.
Function Test-LicenseChange {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)

    $localLicense = $null
    $remoteLicense = $null
    if ($LocalJson.PSObject.Properties['license']) { $localLicense = $LocalJson.license }
    if ($RemoteJson.PSObject.Properties['license']) { $remoteLicense = $RemoteJson.license }

    if ($null -eq $localLicense -And $null -eq $remoteLicense) { return $false }

    $localId = Get-LicenceIdentifier -License $localLicense
    $remoteId = Get-LicenceIdentifier -License $remoteLicense
    $localOpen = Test-IsOpenLicence -Identifier $localId
    $remoteOpen = Test-IsOpenLicence -Identifier $remoteId

    if ($localOpen -And $remoteOpen) {
        if ($localId -ne $remoteId) { Write-LogTrace "      -> Licence changed between open licences ('$localId' -> '$remoteId'); not a concern" }
        return $false
    }

    $localSig = $localLicense | ConvertTo-Json -Depth 10 -Compress
    $remoteSig = $remoteLicense | ConvertTo-Json -Depth 10 -Compress
    return $localSig -ne $remoteSig
}

Function Test-DeepManifestChange {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)

    $localCopy = $LocalJson | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $remoteCopy = $RemoteJson | ConvertTo-Json -Depth 20 | ConvertFrom-Json

    if ($localCopy.PSObject.Properties['##']) { $localCopy.PSObject.Properties.Remove('##') }
    if ($remoteCopy.PSObject.Properties['##']) { $remoteCopy.PSObject.Properties.Remove('##') }

    $localString = $localCopy | ConvertTo-Json -Depth 20 -Compress
    $remoteString = $remoteCopy | ConvertTo-Json -Depth 20 -Compress
    return $localString -ne $remoteString
}

# Compares two version strings token by token (runs of digits compared numerically, runs of letters
# case-insensitively), so 5.10.0 > 5.9.1. Returns -1, 0 or 1 for A <, =, > B.
# A missing token counts as 0 against a number, and as newer than a letter token (so 1.2.0 > 1.2.0-beta).
Function Compare-ManifestVersion {
    param([string]$A, [string]$B)

    $tokensA = @([regex]::Matches([string]$A, '\d+|[a-zA-Z]+') | ForEach-Object { $_.Value })
    $tokensB = @([regex]::Matches([string]$B, '\d+|[a-zA-Z]+') | ForEach-Object { $_.Value })
    $length = [Math]::Max($tokensA.Count, $tokensB.Count)

    for ($i = 0; $i -lt $length; $i++) {
        $x = if ($i -lt $tokensA.Count) { $tokensA[$i] } else { $null }
        $y = if ($i -lt $tokensB.Count) { $tokensB[$i] } else { $null }
        $xNum = $x -match '^\d+$'
        $yNum = $y -match '^\d+$'

        if ($null -eq $x) { if ($yNum) { $x = '0'; $xNum = $true } else { return 1 } }
        if ($null -eq $y) { if ($xNum) { $y = '0'; $yNum = $true } else { return -1 } }

        if ($xNum -And $yNum) {
            # Compare by trimmed length then digits, so arbitrarily long numbers (e.g. dates) work
            $xt = $x.TrimStart('0'); $yt = $y.TrimStart('0')
            if ($xt.Length -ne $yt.Length) { return [Math]::Sign($xt.Length - $yt.Length) }
            $cmp = [string]::CompareOrdinal($xt, $yt)
        }
        elseif ($xNum) { return 1 }
        elseif ($yNum) { return -1 }
        else { $cmp = [string]::Compare($x, $y, $true) }

        if ($cmp -ne 0) { return [Math]::Sign($cmp) }
    }
    return 0
}

Function Test-IsNewerVersion { param ($RemoteVersion, $LocalVersion); return (Compare-ManifestVersion -A $RemoteVersion -B $LocalVersion) -ge 0 }

# Version check lock: version goes backwards, or a pre-release marker is introduced.
Function Test-VersionCheckLock {
    param (
        [string]$LocalVersion,
        [string]$RemoteVersion
    )

    if ([string]::IsNullOrWhiteSpace($LocalVersion) -or [string]::IsNullOrWhiteSpace($RemoteVersion)) { return $false }
    if ($LocalVersion -eq $RemoteVersion) { return $false }

    $versionCompare = Compare-ManifestVersion -A $RemoteVersion -B $LocalVersion
    $remoteHasPrerelease = $RemoteVersion -match '(?i)(alpha|beta)'
    $localHasPrerelease = $LocalVersion -match '(?i)(alpha|beta)'

    if ($versionCompare -lt 0) { return $true }
    if ($remoteHasPrerelease -and -not $localHasPrerelease) { return $true }

    return $false
}

# Compares two manifest objects for significant differences, ignoring version, URL, hash, and extract_dir fields.
Function Compare-ManifestObjects {
    param([PsCustomObject]$ReferenceObject, [PsCustomObject]$DifferenceObject)

    $githubProjectRegex = '^https://github\.com/[^/]+/[^/]+/'
    Function Get-Urls($Object) {
        $urls = @()
        if ($Object.PSObject.Properties['url']) { $urls += $Object.url }
        if ($Object.PSObject.Properties['architecture']) {
            foreach ($arch in $Object.architecture.PSObject.Properties) {
                if ($arch.Value.PSObject.Properties['url']) { $urls += $arch.Value.url }
            }
        }
        return $urls
    }
    $localUrls = Get-Urls -Object $ReferenceObject
    $remoteUrls = Get-Urls -Object $DifferenceObject
    if ($localUrls.Count -gt 0 -And $remoteUrls.Count -gt 0) {
        $localBase = ($localUrls[0] | Select-String -Pattern $githubProjectRegex).Matches.Value
        $remoteBase = ($remoteUrls[0] | Select-String -Pattern $githubProjectRegex).Matches.Value
        if ($localBase -And $remoteBase -And $localBase -ne $remoteBase) {
            Write-LogHighlight "    -> Complex change detected: URL project changed from '$localBase' to '$remoteBase'"
            return $false
        }
    }

    $localNorm = $ReferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $remoteNorm = $DifferenceObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json

    $localNorm = Set-CustomMetadata -JSONObject $localNorm -MetadataToWrite @{}
    $remoteNorm = Set-CustomMetadata -JSONObject $remoteNorm -MetadataToWrite @{}

    $topLevelIgnorable = @('version', 'url', 'hash', 'extract_dir')
    foreach ($key in $topLevelIgnorable) { if ($localNorm.PSObject.Properties[$key]) { $localNorm.PSObject.Properties.Remove($key) }; if ($remoteNorm.PSObject.Properties[$key]) { $remoteNorm.PSObject.Properties.Remove($key) } }

    $propsToClean = @('url', 'hash', 'extract_dir')
    if ($localNorm.PSObject.Properties['architecture']) { foreach ($arch in $localNorm.architecture.PSObject.Properties) { foreach ($prop in $propsToClean) { if ($arch.Value.PSObject.Properties[$prop]) { $arch.Value.PSObject.Properties.Remove($prop) } } } }
    if ($remoteNorm.PSObject.Properties['architecture']) { foreach ($arch in $remoteNorm.architecture.PSObject.Properties) { foreach ($prop in $propsToClean) { if ($arch.Value.PSObject.Properties[$prop]) { $arch.Value.PSObject.Properties.Remove($prop) } } } }

    if ($localNorm.PSObject.Properties['autoupdate']) { if ($localNorm.autoupdate.PSObject.Properties['architecture']) { foreach ($arch in $localNorm.autoupdate.architecture.PSObject.Properties) { if ($arch.Value.PSObject.Properties['url']) { $arch.Value.PSObject.Properties.Remove('url') }; if ($arch.Value.PSObject.Properties['hash']) { $arch.Value.PSObject.Properties.Remove('hash') } } } }
    if ($remoteNorm.PSObject.Properties['autoupdate']) { if ($remoteNorm.autoupdate.PSObject.Properties['architecture']) { foreach ($arch in $remoteNorm.autoupdate.architecture.PSObject.Properties) { if ($arch.Value.PSObject.Properties['url']) { $arch.Value.PSObject.Properties.Remove('url') }; if ($arch.Value.PSObject.Properties['hash']) { $arch.Value.PSObject.Properties.Remove('hash') } } } }

    $localString = $localNorm | ConvertTo-Json -Depth 10 -Compress
    $remoteString = $remoteNorm | ConvertTo-Json -Depth 10 -Compress
    return $localString -eq $remoteString
}

Function Show-ManifestDiff {
    param([PsCustomObject]$LocalJson, [PsCustomObject]$RemoteJson)
    $localCopy = $LocalJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $remoteCopy = $RemoteJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $localCopy = Set-CustomMetadata -JSONObject $localCopy -MetadataToWrite @{}
    $localString = $localCopy | ConvertTo-Json -Depth 10; $remoteString = $remoteCopy | ConvertTo-Json -Depth 10
    $diff = Compare-Object -ReferenceObject ($localString -split '\r?\n') -DifferenceObject ($remoteString -split '\r?\n')
    if ($null -eq $diff) { return }
    Write-Host
    Write-Log "    --- Diff ---"
    foreach ($change in $diff) {
        if ($change.SideIndicator -eq '<=') { Write-Log ("- " + $change.InputObject) "Red" }
        elseif ($change.SideIndicator -eq '=>') { Write-Log ("+ " + $change.InputObject) "Green" }
    }
    Write-Log "    --- End Diff ---`n"
}

Function Show-ManifestCurrent {
    param([PsCustomObject]$Json)
    Write-Host
    Write-Log "    --- Current Manifest ---"
    Write-Host ($Json | ConvertTo-Json -Depth 20)
    Write-Log "    --- End Current Manifest ---`n"
}

# Writes the in-memory data structure to the given file path.
Function Write-Manifest {
    param([PsCustomObject]$MetadataToWrite, [String]$FilePath)
    Write-LogTrace "Writing updated metadata to manifest at '$FilePath'"
    # Keep the sourceLicenceOpen flag in step with the licence actually being written
    $metadata = Get-CustomMetadata $MetadataToWrite
    if ($metadata.Count -gt 0) {
        $metadata.sourceLicenceOpen = Get-LicenceOpenFlag -Json $MetadataToWrite
        $MetadataToWrite = Set-CustomMetadata -JSONObject $MetadataToWrite -MetadataToWrite $metadata
    }
    $MetadataToWrite | ConvertTo-Json -Depth 10 | Set-Content -Path $FilePath -Encoding UTF8
}

# =================================================================================================
# Main Script Logic
# =================================================================================================

$runTimestamp = Get-FormattedDate
$manifests = Get-ChildItem -Path $BucketPath -Filter *.json
$allManifestData = @()

# --- Mode: Normalise Metadata ---
if ($NormaliseMetadata) {
    Write-Host
    Write-Log "Normalising metadata (prefix '$MetadataPrefix', sourceLicenceOpen) on manifests in '$BucketPath'..."
    $changedCount = 0
    foreach ($file in $manifests) {
        if ($file.BaseName -Notmatch $Scope) { continue }
        try { $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json } catch {
            Write-LogWarning "  Could not parse '$($file.Name)': $($_.Exception.Message)"
            continue
        }
        $metadata = Get-CustomMetadata $json
        if ($metadata.Count -eq 0) { continue }
        $flag = Get-LicenceOpenFlag -Json $json
        $needsRewrite = [bool]($json.'##' | Where-Object { Test-MetadataLineNeedsRewrite -Line $_ })
        if ($metadata.sourceLicenceOpen -eq $flag -and -not $needsRewrite) { continue }
        Write-LogVerbose "  -> '$($file.Name)': sourceLicenceOpen = $flag$(if ($needsRewrite) { '; rewriting metadata lines (prefix / source path)' })"
        Write-Manifest -MetadataToWrite $json -FilePath $file.FullName
        $changedCount++
    }
    Write-Log "Normalised metadata on $changedCount manifest(s)"
    return
}

$effectiveDeepComparison = $DeepComparison -or $FullUpdate
$effectiveAutoComplex = $AutoComplex -or $FullUpdate
$effectiveDefaultDelayDays = $DefaultDelayDays
$effectiveDefaultMinimumDays = $DefaultMinimumDays
if ($FullUpdate) {
    $effectiveDefaultDelayDays = 0
    $effectiveDefaultMinimumDays = 0
}

$effectivePullSources = $PullSources -or $FullUpdate
if ($effectivePullSources) {
    $localReposPath = Join-Path -Path $scriptDir -ChildPath 'local-repos.cfg'
    Invoke-PullSourceRepos -ConfigPath $localReposPath -VerboseOutput:$VerboseProcessing
}

# This iterates through all the manifests and gathers their metadata and pending status.
Write-Log "Gathering manifest data from '$BucketPath'..."
foreach ($localManifestFile in $manifests) {
    # Scope filter
    if ($localManifestFile.BaseName -Notmatch $Scope) {
        if ($VerboseProcessing -And -Not $HideSkipped) {
            Write-Log "  -> Skipping '$($localManifestFile.Name)' (does not match scope pattern '$Scope')"
        }
        continue
    }
    $localJson = Get-Content -Path $localManifestFile.FullName -Raw | ConvertFrom-Json
    $metadata = Get-CustomMetadata -JSONObject $localJson
    $data = [pscustomobject]@{ File = $localManifestFile; Local = $localJson; Metadata = $metadata; IsPending = $false; PendingReason = ''; CurrentHash = '' }

    #$lastChangeStr = $data.Metadata.sourceLastChangeFound
    $lastUpdateStr = $data.Metadata.sourceLastUpdated
    $storedHash = $data.Metadata.sourceHash

    $sourcePath = $data.Metadata.source
    if ($sourcePath -And $sourcePath -ne 'MANUAL' -And $sourcePath -ne 'DEPRECATED' -And (Test-Path $sourcePath)) {
        try {
            Write-LogTrace "    -> Checking source date for '$($localManifestFile.Name)' at source path '$sourcePath'"
            $sourceInfo = Get-GitCommitDate -FilePath $sourcePath -StoredHash $storedHash -StoredDate $lastUpdateStr
            $fileUpdateStr = $sourceInfo.Date
            $data.CurrentHash = $sourceInfo.Hash

            # If hash is missing, normalize it now to save future time
            if ([string]::IsNullOrEmpty($storedHash)) {
                Write-LogVerbose "  -> Uninitialized hash for '$($localManifestFile.Name)'. Performing one-off sync..."
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceLastUpdated = $fileUpdateStr
                $newMetadata.sourceHash = $data.CurrentHash
                $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                Write-Manifest -MetadataToWrite $updatedJson -FilePath $localManifestFile.FullName
                $data.Metadata = $newMetadata # Keep object current in memory
            }

            if ($sourceInfo.Match) {
                if ($VerboseProcessing) {
                    Write-Log "  -> Source check for '$($localManifestFile.Name)' shows no update needed (blob hash is unchanged)"
                }
            }
            elseif ($fileUpdateStr -gt $lastUpdateStr) {
                $data.IsPending = $true
                $data.PendingReason = "upstream source updated to $fileUpdateStr after last recorded update on $lastUpdateStr"
                if ($VerboseProcessing) {
                    Write-LogHighlight "  -> Marking '$($localManifestFile.Name)' as pending because the upstream source was updated to $fileUpdateStr which is after the last recorded update on $lastUpdateStr"
                }
            }
            else {
                if ($VerboseProcessing) {
                    Write-Log "  -> Source date check for '$($localManifestFile.Name)' shows no update needed (source date $fileUpdateStr is not after last recorded update on $lastUpdateStr)"
                }
            }
        }
        catch {
            Write-LogVerbose "  -> Warning: Failed to check source date for '$($localManifestFile.Name)'. Error: $($_.Exception.Message)"
        }
    }
    else {
        Write-LogVerbose "  -> Skipping source date check for '$($localManifestFile.Name)' (source path is missing or non-standard or it's a manual or deprecated source)"
    }

    $allManifestData += $data
}

# --- Mode: List Manual ---
if ($ListManual) {
    Write-Host
    Write-LogAttention "Listing manifests marked as MANUAL..."
    $manualFiles = $allManifestData | Where-Object { $_.Metadata.sourceState -eq 'manual' -Or $_.Metadata.source -eq 'MANUAL' }
    if ($manualFiles) {
        $manualFiles | ForEach-Object { Write-Log "  - $($_.File.Name)" }
    }
    else {
        Write-Log "  No manifests are marked as MANUAL"
    }
    return
}

# --- Mode: List Locks ---
if ($ListLocks) {
    Write-Host
    Write-LogAttention "Listing manifests marked as locks (frozen or explicit lock states)..."
    $lockFiles = $allManifestData | Where-Object { $_.Metadata.sourceState -in @('frozen', 'domain-change-lock', 'license-change-lock', 'version-check-lock', 'missing-source-lock') }
    if ($lockFiles) {
        $lockFiles | ForEach-Object { Write-Log "  - $($_.File.Name) [$($_.Metadata.sourceState)]" }
    }
    else {
        Write-Log "  No manifests are marked as locks"
    }
    return
}

$updateableManifests = $allManifestData | Where-Object { $_.Metadata.sourceState -ne 'dead' -And $_.Metadata.sourceState -ne 'manual' }

# --- Mode: List Pending ---
if ($ListPending) {
    Write-Host
    Write-LogAttention "Listing manifests with pending changes..."
    $pendingCount = 0
    foreach ($data in $updateableManifests) {
        if ($data.IsPending) {
            $pendingCount++
            Write-LogHighlight "  - $($data.File.Name) ($($data.PendingReason))"
        }
        elseif ($VerboseList) {
            $updateDate = $data.Metadata.sourceLastUpdated
            Write-Log "  - $($data.File.Name) (authentic source date is $updateDate, skipping)"
        }
    }
    if ($pendingCount -eq 0) { Write-Log "  No non-manual manifests have pending changes" }
    return
}

# --- Mode: Process Locks ---
if ($ProcessLocks) {
    Write-Host
    Write-LogAttention "Starting locked manifest processing..."

    $lockedStates = @('frozen', 'domain-change-lock', 'license-change-lock', 'version-check-lock', 'missing-source-lock')
    $lockedManifests = $allManifestData | Where-Object { $_.Metadata.sourceState -in $lockedStates }
    if ($ExcludeFrozen) {
        $lockedManifests = $lockedManifests | Where-Object { $_.Metadata.sourceState -ne 'frozen' }
    }

    if (-Not $lockedManifests -or $lockedManifests.Count -eq 0) {
        Write-Log "  No locked manifests found to process"
        return
    }

    foreach ($data in $lockedManifests) {
        $sourceUrl = $data.Metadata.sourceUrl
        if (([string]::IsNullOrWhiteSpace($sourceUrl)) -Or ($sourceUrl -Notlike 'http*')) {
            Write-Log "  -> Skipping '$($data.File.Name)' (no valid source URL)" DarkYellow
            continue
        }

        Write-Host
        Write-Log "- Checking locked manifest '$($data.File.Name)' [$($data.Metadata.sourceState)]..."
        $remoteJson = $null
        try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch {
            Write-LogWarning "  Failed to download source for '$($data.File.Name)': $($_.Exception.Message)"
            Resolve-MissingSource -Data $data -RunTimestamp $runTimestamp | Out-Null
            continue
        }

        # Always do deep comparison for lock processing
        $deepChanged = Test-DeepManifestChange -LocalJson $data.Local -RemoteJson $remoteJson

        $hasUpdate = $deepChanged -or ($data.Local.version -ne $remoteJson.version)
        if (-Not $hasUpdate -And -Not $data.IsPending) {
            Write-Log "  No update found for '$($data.File.Name)'; keeping lock state" DarkYellow
            continue
        }

        $lockState = $data.Metadata.sourceState
        Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        if ($lockState -eq 'frozen' -and -not [string]::IsNullOrWhiteSpace($data.Metadata.sourceComment)) {
            Write-LogAttention "    -> sourceComment: $($data.Metadata.sourceComment)"
        }
        $defaultFreezeComment = "Freezing due to checked '$lockState'"
        $freezeCommentPattern = "^Freezing due to checked '([^']+)'$"
        $stripFreezeComment = {
            param([string]$Comment)
            if ([string]::IsNullOrWhiteSpace($Comment)) { return $null }
            $parts = $Comment -split '\s*;\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $filtered = @()
            foreach ($part in $parts) {
                if ($part -notmatch $freezeCommentPattern) { $filtered += $part }
            }
            if ($filtered.Count -eq 0) { return $null }
            return ($filtered -join '; ')
        }

        # Re-assess what is actually blocking this update now, to pick a sensible default action
        $licenceChanged = Test-LicenseChange -LocalJson $data.Local -RemoteJson $remoteJson
        $domainChanged = Test-UrlDomainChange -LocalJson $data.Local -RemoteJson $remoteJson
        $versionConcern = Test-VersionCheckLock -LocalVersion $data.Local.version -RemoteVersion $remoteJson.version
        $concerns = @()
        if ($licenceChanged) { $concerns += 'licence change' }
        if ($domainChanged) { $concerns += 'domain change' }
        if ($versionConcern) { $concerns += 'version regression/pre-release' }
        if ($lockState -ne 'frozen') {
            if ($concerns.Count -eq 0) { Write-LogHighlight "    -> The '$lockState' condition is no longer detected for this update" }
            else { Write-LogConcern "    -> Still detected: $($concerns -join ', ')" }
        }

        # Defaults: frozen stays frozen (skip); any licence concern freezes; domain/version locks accept
        $defaultChoice = switch ($lockState) {
            'frozen' { 's' }
            'missing-source-lock' { 's' }
            'license-change-lock' { 'f' }
            default { 'a' }
        }
        if ($licenceChanged -and $lockState -ne 'frozen') { $defaultChoice = 'f' }

        :lockPrompt while ($true) {
            $choice = Get-ChangeDecision -Prompt "-> This package is locked ($lockState). Process and unlock? (A)ccept / (F)reeze / (S)kip / (D)isplay / (Q)uit" -Default $defaultChoice -Allowed @('a', 'f', 's', 'd', 'q')
            switch ($choice) {
                'd' {
                    Show-ManifestCurrent -Json $data.Local
                    Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
                    continue lockPrompt
                }
                'a' {
                    $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                    $newMetadata = $data.Metadata.Clone()
                    $newMetadata.sourceState = 'active'
                    $newMetadata.sourceLastUpdated = $sourceInfo.Date
                    $newMetadata.sourceHash = $sourceInfo.Hash
                    $newMetadata.sourceLastChangeFound = $runTimestamp
                    if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
                        $newMetadata.Remove('sourceDeferredUpdateFound')
                    }
                    if ($newMetadata.ContainsKey('sourceComment')) {
                        $cleanedComment = & $stripFreezeComment $newMetadata.sourceComment
                        if ([string]::IsNullOrWhiteSpace($cleanedComment)) {
                            $newMetadata.Remove('sourceComment')
                        }
                        else {
                            $newMetadata.sourceComment = $cleanedComment
                        }
                        if (-not $newMetadata.ContainsKey('sourceNotes')) {
                            $newMetadata.sourceNotes = ''
                        }
                    }
                    $updatedJson = Set-CustomMetadata -JSONObject $remoteJson -MetadataToWrite $newMetadata
                    Write-Log "    -> Writing updated state to manifest..."
                    Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
                    Write-Log "  Accepted and unlocked '$($data.File.Name)'" Green
                    break lockPrompt
                }
                'f' {
                    $commentInput = Read-Host "-> Enter freeze comment (default: $defaultFreezeComment)"
                    if ([string]::IsNullOrWhiteSpace($commentInput)) {
                        $commentInput = $defaultFreezeComment
                    }

                    $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                    $newMetadata = $data.Metadata.Clone()
                    $newMetadata.sourceState = 'frozen'
                    $newMetadata.sourceLastUpdated = $sourceInfo.Date
                    $newMetadata.sourceHash = $sourceInfo.Hash
                    $newMetadata.sourceLastChangeFound = $runTimestamp

                    $existingComment = $newMetadata.sourceComment
                    if ([string]::IsNullOrWhiteSpace($existingComment)) {
                        $newMetadata.sourceComment = $commentInput
                    }
                    elseif ($existingComment -notmatch [regex]::Escape($commentInput)) {
                        $newMetadata.sourceComment = "$existingComment; $commentInput"
                    }

                    if (-not $newMetadata.ContainsKey('sourceNotes')) {
                        $newMetadata.sourceNotes = ''
                    }

                    $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                    Write-Log "    -> Writing updated freeze state to manifest..."
                    Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
                    Write-Log "  Frozen '$($data.File.Name)'" Yellow
                    break lockPrompt
                }
                'q' {
                    Write-Log "Aborting lock processing session"
                    return
                }
                's' {
                    Write-LogWarning "  Skipped '$($data.File.Name)'; keeping lock state"
                    break lockPrompt
                }
            }
        }
    }

    Write-Host
    Write-Log "Locked manifest processing complete"
    return
}

# --- Mode: Interactive ---
if ($Interactive) {
    Write-Host
    Write-LogAttention "Starting interactive update session..."
    $updateCandidates = 0
    foreach ($data in $updateableManifests) {
        # Exclude frozen if requested
        if ($ExcludeFrozen -and $data.Metadata.sourceState -eq 'frozen') {
            Write-LogAttention "  -> Skipping frozen package '$($data.File.Name)' due to -ExcludeFrozen flag"
            continue
        }
        $sourceUrl = $data.Metadata.sourceUrl
        if (([string]::IsNullOrWhiteSpace($sourceUrl)) -Or ($sourceUrl -Notlike 'http*')) { continue }
        Write-Host
        Write-Log "- Checking '$($data.File.Name)'..."
        $remoteJson = $null
        try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch {
            Write-LogWarning "  Failed to download source for '$($data.File.Name)': $($_.Exception.Message)"
            Resolve-MissingSource -Data $data -RunTimestamp $runTimestamp | Out-Null
            continue
        }

        $deepChanged = $false
        if ($effectiveDeepComparison) {
            $deepChanged = Test-DeepManifestChange -LocalJson $data.Local -RemoteJson $remoteJson
        }

        if (Test-VersionCheckLock -LocalVersion $data.Local.version -RemoteVersion $remoteJson.version) {
            Write-LogConcern "    Version change requires manual review; locking package (version-check-lock)"
            $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
            $newMetadata = $data.Metadata.Clone()
            $newMetadata.sourceState = 'version-check-lock'
            $newMetadata.sourceLastUpdated = $sourceInfo.Date
            $newMetadata.sourceHash = $sourceInfo.Hash
            $newMetadata.sourceLastChangeFound = $runTimestamp
            $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
            Write-Log "    -> Writing updated state to manifest..."
            Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
            continue
        }

        if (-Not $deepChanged -And $data.Local.version -eq $remoteJson.version -And -Not $data.IsPending) { continue }
        if (-Not $deepChanged -And $data.Local.version -ne $remoteJson.version -And -Not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) { continue }

        Write-LogHighlight "--- Reviewing '$($data.File.Name)' ---"

        $proceedToStandardPrompt = $false
        if ($data.Metadata.sourceState -eq 'domain-change-lock') {
            Write-LogAttention "  -> Skipping package due to domain-change-lock"
            continue
        }
        if ($data.Metadata.sourceState -eq 'license-change-lock') {
            Write-LogAttention "  -> Skipping package due to license-change-lock"
            continue
        }
        if ($data.Metadata.sourceState -eq 'version-check-lock') {
            Write-LogAttention "  -> Skipping package due to version-check-lock"
            continue
        }
        if ($data.Metadata.sourceState -eq 'missing-source-lock') {
            Write-LogAttention "  -> Skipping package due to missing-source-lock"
            continue
        }
        if ($data.Metadata.sourceState -eq 'frozen') {
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            $frozenChoice = Read-Host "-> This package is FROZEN. Skip this update? (Y)es / (N)o [Enter = Yes, leave frozen]"
            if ([string]::IsNullOrWhiteSpace($frozenChoice)) { $frozenChoice = 'y' }
            if ($frozenChoice.ToLower() -eq 'n') {
                $proceedToStandardPrompt = $true
            }
            else {
                Write-LogAttention "  -> Skipping frozen package as requested"
                Set-DeferredUpdateFound -Data $data -RunTimestamp $runTimestamp | Out-Null
                continue
            }
        }
        else {
            $proceedToStandardPrompt = $true
        }

        if ($proceedToStandardPrompt) {
            $updateCandidates++
            if ($data.Metadata.sourceState -ne 'frozen') {
                Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            }

            if (Test-LicenseChange -LocalJson $data.Local -RemoteJson $remoteJson) {
                Write-LogConcern "    License change concern detected. Locking package for manual review (license-change-lock)"
                $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceState = 'license-change-lock'
                $newMetadata.sourceLastUpdated = $sourceInfo.Date
                $newMetadata.sourceHash = $sourceInfo.Hash
                $newMetadata.sourceLastChangeFound = $runTimestamp
                $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                Write-Log "    -> Writing updated state to manifest..."
                Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
                continue
            }
            else {
                Write-LogTrace "    -> No license change concern detected"
            }

            if (Test-UrlDomainChange -LocalJson $data.Local -RemoteJson $remoteJson) {
                Write-LogConcern "    URL domain change detected. Locking package for manual review (domain-change-lock)"
                $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
                $newMetadata = $data.Metadata.Clone()
                $newMetadata.sourceState = 'domain-change-lock'
                $newMetadata.sourceLastUpdated = $sourceInfo.Date
                $newMetadata.sourceHash = $sourceInfo.Hash
                $newMetadata.sourceLastChangeFound = $runTimestamp
                $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
                Write-Log "    -> Writing updated state to manifest..."
                Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
                continue
            }
            else {
                Write-LogTrace "    -> No URL domain change detected"
            }

            $delayDays = $effectiveDefaultDelayDays
            if (-Not $FullUpdate -And $data.Metadata.sourceDelayDays -match '^\d+$') { $delayDays = [int]$data.Metadata.sourceDelayDays }
            if ($delayDays -gt 0) {
                try {
                    $updateDate = [datetime]::ParseExact($data.Metadata.sourceLastUpdated, $timestampFormat, $null)
                    $updateAge = (Get-Now) - $updateDate
                    if ($updateAge.TotalDays -lt $delayDays) {
                        Write-LogWarning "This source update is only $($updateAge.TotalDays.ToString('F0')) days old, which is within the $($delayDays)-day delay period"
                    }
                }
                catch {
                    Write-LogWarning "Manifest $($data.File.Name) has no recorded last update date or other problem reading; cannot enforce delay days"
                }
            }
            $minDays = $effectiveDefaultMinimumDays
            if (-Not $FullUpdate -And $data.Metadata.sourceUpdateMinimumDays -match '^\d+$') { $minDays = [int]$data.Metadata.sourceUpdateMinimumDays }
            if ($minDays -gt 0) {
                try {
                    $changeDate = [datetime]::ParseExact($data.Metadata.sourceLastChangeFound, $timestampFormat, $null)
                    $lastChangeAge = (Get-Now) - $changeDate
                    if ($lastChangeAge.TotalDays -lt $minDays) {
                        Write-LogWarning "This manifest was last updated only $($lastChangeAge.TotalDays.ToString('F0')) day(s) ago (minimum is $($minDays))"
                    }
                }
                catch {
                    Write-LogWarning "Manifest $($data.File.Name) has no recorded last change date or other problem reading; cannot enforce minimum update days"
                }
            }

            # Licence changes have already locked and moved on above, so accepting is the default here
            while ($true) {
                $choice = Get-ChangeDecision -Prompt "Apply this change? (A)ccept / (F)reeze / (S)kip / (D)isplay / (Q)uit" -Default 'a' -Allowed @('a', 'f', 's', 'd', 'q')
                if ($choice -eq 'd') {
                    Show-ManifestCurrent -Json $data.Local
                    Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
                    continue
                }
                if (-Not (Invoke-ChangeDecision -Choice $choice -Data $data -RemoteJson $remoteJson -RunTimestamp $runTimestamp -RecordDeferredOnSkipOrFreeze)) {
                    return
                }
                break
            }
        }
    }
    if ($updateCandidates -eq 0) {
        Write-Host
        Write-Log "  No manifests have pending changes to review"
    }
    Write-Host
    Write-Log "Interactive session complete"
    return
}

# --- Mode: Default Automatic Update ---
Write-Host
Write-Log "Checking for updates in '$BucketPath'..."
foreach ($data in $updateableManifests) {
    $sourceUrl = $data.Metadata.sourceUrl
    if (([string]::IsNullOrWhiteSpace($sourceUrl)) -Or ($sourceUrl -Notlike 'http*')) { continue }

    if ($data.Metadata.sourceState -eq 'frozen') {
        if (-Not $ChangesOnly) {
            Write-Host
            Write-Log "  - Checking '$($data.File.Name)'..."
            Write-LogAttention "    -> Package is frozen; skipping all processing"
        }
        continue
    }

    # CHURN GUARD: Determine the authentic status of the source file BEFORE doing anything else
    $sourceInfo = Get-GitCommitDate -FilePath $data.Metadata.source -StoredHash $data.Metadata.sourceHash -StoredDate $data.Metadata.sourceLastUpdated
    $authenticSourceDate = $sourceInfo.Date
    $currentHash = $sourceInfo.Hash

    $remoteJson = $null
    try { $remoteJson = Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing | ConvertFrom-Json } catch {
        if (-Not $ChangesOnly) {
            Write-Host
            Write-Log "  - Checking '$($data.File.Name)'..."
            Write-LogWarning "    Failed to download source. Error: $($_.Exception.Message)"
        }
        Resolve-MissingSource -Data $data -RunTimestamp $runTimestamp | Out-Null
        continue
    }

    $deepChanged = $false
    if ($effectiveDeepComparison) {
        $deepChanged = Test-DeepManifestChange -LocalJson $data.Local -RemoteJson $remoteJson
    }

    if (Test-VersionCheckLock -LocalVersion $data.Local.version -RemoteVersion $remoteJson.version) {
        Write-LogConcern "    Version change requires manual review; locking package (version-check-lock)"
        $newMetadata = $data.Metadata.Clone()
        $newMetadata.sourceState = 'version-check-lock'
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        Write-Log "      -> Writing updated state to manifest..."
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
        continue
    }

    $hasUpdate = $deepChanged -or (($data.Local.version -ne $remoteJson.version) -And (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version))
    $sourceFileChanged = ($authenticSourceDate -gt $data.Metadata.sourceLastUpdated)

    # If no version jump AND the source file is exactly where we last left it, skip the manifest.
    if (-Not $hasUpdate -And -Not $sourceFileChanged) {
        if (-Not $ChangesOnly) {
            Write-Host
            Write-Log "  - Checking '$($data.File.Name)'..."
            Write-Log "    Already up to date (version $($data.Local.version))"
        }
        continue
    }

    Write-Host
    Write-Log "  - Checking '$($data.File.Name)'..."

    if (-Not $hasUpdate -And $sourceFileChanged) {
        Write-Log "    Already up to date (version $($data.Local.version))"
        $newMetadata = $data.Metadata.Clone();
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        Write-Log "      -> Syncing timestamps: authentic date is $authenticSourceDate"
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
        continue
    }

    if (-Not $deepChanged -And $data.Local.version -ne $remoteJson.version -And -Not (Test-IsNewerVersion -RemoteVersion $remoteJson.version -LocalVersion $data.Local.version)) {
        Write-LogConcern "    Halted; remote version ($($remoteJson.version)) is older than local version ($($data.Local.version))"
        continue
    }

    Write-Log "    - Local version: $($data.Local.version), Remote version: $($remoteJson.version); update available"

    # Release automatic locks whose triggering condition no longer applies (e.g. after detection rules improve);
    # the update then goes through the normal checks below, which will re-lock it if needed.
    # (A version-check concern was handled above, before reaching here.)
    if ($data.Metadata.sourceState -in @('domain-change-lock', 'license-change-lock', 'version-check-lock')) {
        if (-Not (Test-LicenseChange -LocalJson $data.Local -RemoteJson $remoteJson) -And -Not (Test-UrlDomainChange -LocalJson $data.Local -RemoteJson $remoteJson)) {
            Write-LogHighlight "    -> '$($data.Metadata.sourceState)' condition no longer detected; releasing lock"
            $data.Metadata.sourceState = 'active'
        }
    }

    if ($data.Metadata.sourceState -in @('frozen', 'domain-change-lock', 'license-change-lock', 'version-check-lock', 'missing-source-lock')) {
        $stateLabel = $data.Metadata.sourceState
        Write-LogAttention "    -> Update found for locked package (${stateLabel}); no action will be taken"
        if (-Not $SkipFrozen) {
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        }
        continue
    }

    $deferredDate = Get-DeferredUpdateDate -Metadata $data.Metadata

    $minDays = $effectiveDefaultMinimumDays
    if (-Not $FullUpdate -And $data.Metadata.sourceUpdateMinimumDays -match '^\d+$') { $minDays = [int]$data.Metadata.sourceUpdateMinimumDays }
    if ($minDays -gt 0) {
        try {
            $changeDate = [datetime]::ParseExact($data.Metadata.sourceLastChangeFound, $timestampFormat, $null)
            $lastChangeAge = (Get-Now) - $changeDate
            if ($lastChangeAge.TotalDays -lt $minDays) {
                Write-LogConcern "    -> Update found, but logging only; manifest was updated $($lastChangeAge.TotalDays.ToString('F0')) day(s) ago (minimum is $($minDays))"
                Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
                continue
            }
        }
        catch {}
    }

    $delayDays = $effectiveDefaultDelayDays
    if (-Not $FullUpdate -And $data.Metadata.sourceDelayDays -match '^\d+$') { $delayDays = [int]$data.Metadata.sourceDelayDays }
    if ($delayDays -gt 0) {
        try {
            $updateDate = [datetime]::ParseExact($data.Metadata.sourceLastUpdated, $timestampFormat, $null)
            $updateAge = (Get-Now) - $updateDate
            if ($updateAge.TotalDays -lt $delayDays) {
                $deferredAge = $null
                if ($deferredDate) { $deferredAge = (Get-Now) - $deferredDate }
                if ($deferredAge -And $deferredAge.TotalDays -ge $delayDays) {
                    Write-LogVerbose "    -> Deferred update exceeds delay window; proceeding with update"
                }
                else {
                    Write-LogConcern "    -> Update found, but source change is too recent to apply (within $($delayDays)-day delay period); skipping..."
                    Set-DeferredUpdateFound -Data $data -RunTimestamp $runTimestamp | Out-Null
                    continue
                }
            }
        }
        catch {}
    }

    if (Test-LicenseChange -LocalJson $data.Local -RemoteJson $remoteJson) {
        Write-LogConcern "    License change detected. Locking package for manual review (license-change-lock)"
        $newMetadata = $data.Metadata.Clone()
        $newMetadata.sourceState = 'license-change-lock'
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        Write-Log "      -> Writing updated state to manifest..."
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
        continue
    }

    if (Test-UrlDomainChange -LocalJson $data.Local -RemoteJson $remoteJson) {
        Write-LogConcern "    URL domain change detected. Locking package for manual review (domain-change-lock)"
        $newMetadata = $data.Metadata.Clone()
        $newMetadata.sourceState = 'domain-change-lock'
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata
        Write-Log "      -> Writing updated state to manifest..."
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
        continue
    }

    if (Compare-ManifestObjects -ReferenceObject $data.Local -DifferenceObject $remoteJson) {
        Write-Log "    Simple version change detected in $($data.File.Name); auto-updating..."
        $data.Local.version = $remoteJson.version
        # These fields may or may not exist; update or remove as needed
        if ($remoteJson.PSObject.Properties['url']) { $data.Local.url = $remoteJson.url } elseif ($data.Local.PSObject.Properties['url']) { $data.Local.PSObject.Properties.Remove('url') }
        if ($remoteJson.PSObject.Properties['hash']) { $data.Local.hash = $remoteJson.hash } elseif ($data.Local.PSObject.Properties['hash']) { $data.Local.PSObject.Properties.Remove('hash') }
        if ($remoteJson.PSObject.Properties['extract_dir']) { $data.Local.extract_dir = $remoteJson.extract_dir } elseif ($data.Local.PSObject.Properties['extract_dir']) { $data.Local.PSObject.Properties.Remove('extract_dir') }
        if ($remoteJson.PSObject.Properties['architecture']) { $data.Local.architecture = $remoteJson.architecture } elseif ($data.Local.PSObject.Properties['architecture']) { $data.Local.PSObject.Properties.Remove('architecture') }
        if ($remoteJson.PSObject.Properties['autoupdate']) { $data.Local.autoupdate = $remoteJson.autoupdate } elseif ($data.Local.PSObject.Properties['autoupdate']) { $data.Local.PSObject.Properties.Remove('autoupdate') }

        $newMetadata = $data.Metadata.Clone();
        $newMetadata.sourceLastUpdated = $authenticSourceDate
        $newMetadata.sourceHash = $currentHash
        $newMetadata.sourceLastChangeFound = $runTimestamp
        if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
            $newMetadata.Remove('sourceDeferredUpdateFound')
        }
        $updatedJson = Set-CustomMetadata -JSONObject $data.Local -MetadataToWrite $newMetadata

        Write-Log "      -> Writing updated version and timestamps to '$($data.File.Name)'"
        Write-Manifest -MetadataToWrite $updatedJson -FilePath $data.File.FullName
    }
    else {

        if ($InteractiveComplex) {
            Write-LogConcern "    Manifest $($data.File.Name) has complex changes; interactive review enabled"
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            # Licence changes have already locked and moved on above, so accepting is the default here
            $choice = Get-ChangeDecision -Default 'a'
            $sourceInfo = [pscustomobject]@{ Date = $authenticSourceDate; Hash = $currentHash }
            if (-Not (Invoke-ChangeDecision -Choice $choice -Data $data -RemoteJson $remoteJson -RunTimestamp $runTimestamp -SourceInfo $sourceInfo)) {
                return
            }
        }
        elseif ($effectiveAutoComplex) {
            Write-LogConcern "    Manifest $($data.File.Name) has complex changes. AutoComplex enabled; applying changes"
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
            $newMetadata = $data.Metadata.Clone()
            $newMetadata.sourceLastUpdated = $authenticSourceDate
            $newMetadata.sourceHash = $currentHash
            $newMetadata.sourceLastChangeFound = $runTimestamp
            if ($newMetadata.ContainsKey('sourceDeferredUpdateFound')) {
                $newMetadata.Remove('sourceDeferredUpdateFound')
            }
            $newJson = Set-CustomMetadata -JSONObject $remoteJson -MetadataToWrite $newMetadata
            Write-Log "      -> Writing complex changes to '$($data.File.Name)'"
            Write-Manifest -MetadataToWrite $newJson -FilePath $data.File.FullName
        }
        else {
            Write-LogConcern "    Manifest $($data.File.Name) has complex changes; manual review required"
            Show-ManifestDiff -LocalJson $data.Local -RemoteJson $remoteJson
        }
    }
}
Write-Host
Write-Log "Update check complete"
