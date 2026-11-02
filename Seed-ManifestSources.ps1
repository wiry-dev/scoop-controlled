<#
.SYNOPSIS
  Seeds Scoop manifests with source info and initializes tracking fields using the schema-conformant "##" property.

.DESCRIPTION
  This script inspects 'local-repos.cfg' and finds the upstream source for each manifest in this bucket.
  It adds source metadata as an array of "key: value" strings under the "##" property, including:
  - source: The local file path of the original manifest.
  - sourceUrl: The remote raw GitHub URL.
  - sourceLastUpdated: Timestamp of the source file's last modification.
  - sourceLastChangeFound: Timestamp when a change was last detected by the update script.
  - sourceState: The update status of the package ('active', 'manual', 'frozen', 'dead').

.PARAMETER BucketPath
  The path to the 'bucket' directory to process. Defaults to the 'bucket' folder next to this script.

.PARAMETER Force
  Forces recalculation for ALL manifests, ignoring their current state.

.PARAMETER RecalculateManual
  Recalculates only for manifests currently marked as 'MANUAL'.

.PARAMETER ReprocessIncomplete
  Corrects any manifest missing 'source'/'sourceUrl', with empty timestamps, or where the 'sourceLastUpdated' timestamp does not match the source file's modification time.

.PARAMETER RefreshAllFoundChangeTimestamps
  Updates the 'sourceLastChangeFound' timestamp to the current time for all non-manual manifests.

.PARAMETER SeedStates
  Initializes the 'sourceState' metadata field for all manifests without changing other data.

.PARAMETER ListManual
  Lists all manifests marked as 'MANUAL' and exits without taking any other action.

.PARAMETER MigrateTimestampFormat
  Performs a one-time migration of 'sourceLastUpdated' and 'sourceLastChangeFound' from "MM/dd/yyyy HH:mm:ss" to "yyMMdd HH:mm:ss" format.

.PARAMETER MigrateFormat
  Performs a one-time migration, converting old top-level 'source*' keys to the new "##" format in all manifests.

.PARAMETER FixUnsplitComments
  Repairs manifests where a previous migration incorrectly concatenated all metadata into a single comment string.

.PARAMETER CleanComments
  Removes duplicate standalone metadata keys (e.g., "source") from the "##" array, which may have been created during repair.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$BucketPath = $null,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$RecalculateManual,

    [Parameter(Mandatory = $false)]
    [switch]$ReprocessIncomplete,

    [Parameter(Mandatory = $false)]
    [switch]$RefreshAllFoundChangeTimestamps,

    [Parameter(Mandatory = $false)]
    [switch]$SeedStates,

    [Parameter(Mandatory = $false)]
    [switch]$ListManual,

    [Parameter(Mandatory = $false)]
    [switch]$MigrateTimestampFormat,

    [Parameter(Mandatory = $false)]
    [switch]$MigrateFormat,

    [Parameter(Mandatory = $false)]
    [switch]$FixUnsplitComments,

    [Parameter(Mandatory = $false)]
    [switch]$CleanComments
)

# --- Initial Setup ---
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($BucketPath)) {
    $BucketPath = Join-Path -Path $scriptDir -ChildPath 'bucket'
}

$ConfigFile = "local-repos.cfg"
if (-not (Test-Path $BucketPath)) { Write-Error "Bucket path not found: $BucketPath"; return }
$bucketManifests = Get-ChildItem -Path $BucketPath -Filter *.json
if ($null -eq $bucketManifests) { Write-Warning "No manifest files found in '$BucketPath'."; return }

# =================================================================================
# Helper Functions
# =================================================================================
# Metadata key list and line prefix ($MetadataPrefix) are shared with the other scripts
. (Join-Path -Path $PSScriptRoot -ChildPath 'ManifestMetadata.ps1')

Function Get-SortedManifestComments {

    param(
        [array]$Comments
    )

    $nonMetadata = @()
    $metadataEntries = @()
    foreach ($line in $Comments) {
        $entry = ConvertFrom-MetadataLine -Line $line
        if ($entry) { $metadataEntries += $entry }
        else { $nonMetadata += $line }
    }

    $sortedMetadata = $metadataEntries | Sort-Object Key | ForEach-Object { ConvertTo-MetadataLine -Key $_.Key -Value $_.Value }
    return @($nonMetadata + $sortedMetadata)
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

Function Set-CustomMetadata($JSONObject, $MetadataToWrite) {
    if (-not $JSONObject.PSObject.Properties['##']) {
        $JSONObject | Add-Member -MemberType NoteProperty -Name '##' -Value @()
    }
    elseif ($JSONObject.'##' -isnot [array]) {
        $JSONObject.'##' = @($JSONObject.'##')
    }
    $newComments = @($JSONObject.'##' | Where-Object { -not (Test-MetadataLine -Line $_) })
    foreach ($entry in ($MetadataToWrite.GetEnumerator() | Sort-Object Key)) {
        $newComments += ConvertTo-MetadataLine -Key $entry.Key -Value $entry.Value
    }
    $JSONObject.'##' = Get-SortedManifestComments -Comments $newComments
    return $JSONObject
}

# =================================================================================
# Corrective/Migration Modes (These run exclusively)
# =================================================================================
if ($SeedStates) {
    Write-Host "🌱 Seeding 'sourceState' for all manifests..." -ForegroundColor Cyan
    $seededCount = 0
    foreach ($manifestFile in $bucketManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        $metadata = Get-CustomMetadata -JSONObject $json
        if (-not $metadata.ContainsKey('sourceState')) {
            if ($metadata.source -eq 'MANUAL') { $metadata.sourceState = 'manual' }
            else { $metadata.sourceState = 'active' }
            Write-Host "  - Setting state for '$($manifestFile.Name)' to '$($metadata.sourceState)'."
            $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadata
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
            $seededCount++
        }
    }
    Write-Host "✨ State seeding complete. Updated $seededCount manifest(s)." -ForegroundColor Green
    return
}

if ($RefreshAllFoundChangeTimestamps) {
    Write-Host "🔄 Refreshing all 'sourceLastChangeFound' timestamps..." -ForegroundColor Cyan
    $runTimestamp = (Get-Date).ToString("yyMMdd HH:mm:ss")
    $refreshedCount = 0
    foreach ($manifestFile in $bucketManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        $metadata = Get-CustomMetadata -JSONObject $json
        if ($metadata.source -ne 'MANUAL') {
            $metadata.sourceLastChangeFound = $runTimestamp
            $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadata
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
            $refreshedCount++
        }
    }
    Write-Host "✨ Refresh complete. Updated $refreshedCount manifest(s)." -ForegroundColor Green
    return
}

if ($MigrateTimestampFormat) {
    Write-Host "🕰️  Migrating timestamp formats in manifest comments..." -ForegroundColor Cyan
    $migratedCount = 0; $oldFormat = "MM/dd/yyyy HH:mm:ss"; $newFormat = "yyMMdd HH:mm:ss"
    foreach ($manifestFile in $bucketManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json; $metadata = Get-CustomMetadata -JSONObject $json; $wasModified = $false
        foreach ($key in @('sourceLastUpdated', 'sourceLastChangeFound')) {
            if ($metadata.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($metadata[$key])) {
                try {
                    $dateObject = [datetime]::ParseExact($metadata[$key], $oldFormat, $null); $newTimestamp = $dateObject.ToString($newFormat)
                    if ($metadata[$key] -ne $newTimestamp) { $metadata[$key] = $newTimestamp; $wasModified = $true }
                }
                catch {}
            }
        }
        if ($wasModified) {
            Write-Host "  - Updating timestamps in '$($manifestFile.Name)'..."; $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadata
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $migratedCount++
        }
    }
    Write-Host "✨ Timestamp migration complete. Updated $migratedCount manifest(s)." -ForegroundColor Green; return
}

if ($CleanComments) {
    Write-Host "🧹 Cleaning duplicate standalone keys from manifest comments..." -ForegroundColor Cyan; $cleanedCount = 0; $keySet = [System.Collections.Generic.HashSet[string]]$MetadataKeys
    foreach ($manifestFile in $bucketManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['##'] -and $json.'##' -is [array]) {
            $originalComments = $json.'##'; $commentsToKeep = @()
            foreach ($line in $originalComments) { if (($line -like '*:*') -or (-not $keySet.Contains($line))) { $commentsToKeep += $line } }
            if ($commentsToKeep.Count -lt $originalComments.Count) {
                Write-Host "  - Cleaning '$($manifestFile.Name)'..."; $json.'##' = Get-SortedManifestComments -Comments $commentsToKeep
                $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $cleanedCount++
            }
        }
    }
    Write-Host "✨ Cleaning complete. Cleaned $cleanedCount manifest(s)." -ForegroundColor Green; return
}

if ($FixUnsplitComments) {
    Write-Host "🔧 Repairing manifests with unsplit comment strings..." -ForegroundColor Cyan; $repairedCount = 0; $splitKeys = 'sourceUrl|sourceLastUpdated|sourceLastChangeFound|source|sourceState'
    foreach ($manifestFile in $bucketManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['##'] -and $json.'##' -is [string]) {
            $commentString = $json.'##'; $repairedArray = $commentString -split "(?=($splitKeys)\s*:)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
            if ($repairedArray.Count -gt 1) {
                Write-Host "  - Repairing '$($manifestFile.Name)'..."; $json.'##' = Get-SortedManifestComments -Comments $repairedArray
                $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $repairedCount++
            }
            else { Write-Warning "    - Could not parse '$($manifestFile.Name)'. Skipping." }
        }
    }
    Write-Host "✨ Repair complete. Repaired $repairedCount manifest(s)." -ForegroundColor Green; return
}

if ($MigrateFormat) {
    Write-Host "🚀 Migrating manifest formats to use the '##' property..." -ForegroundColor Cyan; $migratedCount = 0
    foreach ($manifestFile in $bucketManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json; $oldKeys = $json.PSObject.Properties.Name | Where-Object { $MetadataKeys -contains $_ }
        if ($oldKeys.Count -gt 0) {
            Write-Host "  - Migrating '$($manifestFile.Name)'..."; $metadataToMigrate = @{}; foreach ($key in $oldKeys) { $metadataToMigrate[$key] = $json.$key }
            $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToMigrate; foreach ($key in $oldKeys) { $json.PSObject.Properties.Remove($key) }
            $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8; $migratedCount++
        }
    }
    Write-Host "✨ Migration complete. Migrated $migratedCount manifest(s)." -ForegroundColor Green; return
}

if ($ListManual) {
    Write-Host "📜 Listing applications marked as MANUAL..." -ForegroundColor Cyan; $manualApps = @()
    foreach ($manifestFile in $bucketManifests) {
        $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -ne $json) { $metadata = Get-CustomMetadata -JSONObject $json; if ($metadata.source -eq 'MANUAL') { $manualApps += $manifestFile.Name } }
    }
    if ($manualApps.Count -gt 0) { $manualApps | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  ✅ No applications are marked as MANUAL." }; return
}

# =================================================================================
# Main Seeding Operation
# =================================================================================
$configFilePath = Join-Path -Path $scriptDir -ChildPath $ConfigFile
if (-not (Test-Path $configFilePath)) { Write-Error "Config file not found: $configFilePath"; return }
Write-Host "🔍 Reading and verifying repository configuration from '$configFilePath'..."
Assert-SourcesRoot
$repos = Get-LocalRepoEntries -ConfigPath $configFilePath -BaseDir $scriptDir

$runTimestamp = (Get-Date).ToString("yyMMdd HH:mm:ss")
$modifiedFileCount = 0
Write-Host "`n🌱 Seeding source information for manifests in '$BucketPath'..."
if ($Force) { Write-Host "  -Force switch detected. All existing source values will be recalculated." -ForegroundColor Yellow }
if ($RecalculateManual) { Write-Host "  -RecalculateManual switch detected. Only 'MANUAL' entries will be recalculated." -ForegroundColor Yellow }
if ($ReprocessIncomplete) { Write-Host "  -ReprocessIncomplete switch detected. Incomplete manifests will be corrected." -ForegroundColor Yellow }

foreach ($manifestFile in $bucketManifests) {
    $json = Get-Content -Path $manifestFile.FullName -Raw | ConvertFrom-Json
    $metadata = Get-CustomMetadata -JSONObject $json
    $metadataToUpdate = $metadata.Clone()
    $wasModified = $false
    $logMessages = @()

    $isManual = $metadata.ContainsKey('source') -and $metadata.source -eq 'MANUAL'

    if ($Force -or ($RecalculateManual -and $isManual)) {
        $sourceFound = $false; $deprecatedFound = $false; $recalculatedMeta = @{}
        foreach ($repo in $repos) {
            $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
            if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", ""); $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/bucket/$($manifestFile.Name)"
                $recalculatedMeta = @{ source = $sourceManifestPath; sourceUrl = $rawUrl }; $sourceFound = $true; break
            }
        }
        if (-not $sourceFound) {
            foreach ($repo in $repos) {
                $deprecatedManifestPath = Join-Path $repo.Path "deprecated\$($manifestFile.Name)"
                if ((Test-Path $deprecatedManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                    $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", ""); $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/deprecated/$($manifestFile.Name)"
                    $recalculatedMeta = @{ source = 'DEPRECATED'; sourceUrl = $rawUrl }; $deprecatedFound = $true; break
                }
            }
        }
        if (-not $sourceFound -and -not $deprecatedFound) { $recalculatedMeta = @{ source = 'MANUAL' } }
        $metadataToUpdate = $recalculatedMeta
        $logMessages += "    -> Recalculated source due to -Force or -RecalculateManual flag."
    }
    elseif ($ReprocessIncomplete) {
        if (-not $metadata.ContainsKey('source') -or -not $metadata.ContainsKey('sourceUrl')) {
            $sourceFound = $false
            foreach ($repo in $repos) {
                $sourceManifestPath = Join-Path $repo.Path "bucket\$($manifestFile.Name)"
                if ((Test-Path $sourceManifestPath) -and (-not [string]::IsNullOrWhiteSpace($repo.Url))) {
                    $repoBase = $repo.Url.Replace(".git", "").Replace("git@github.com:", "https://github.com/"); $userRepo = $repoBase.Replace("https://github.com/", ""); $rawUrl = "https://raw.githubusercontent.com/$userRepo/master/bucket/$($manifestFile.Name)"
                    $logMessages += "    -> Found missing source: $sourceManifestPath"; $metadataToUpdate.source = $sourceManifestPath
                    $logMessages += "    -> Found missing sourceUrl: $rawUrl"; $metadataToUpdate.sourceUrl = $rawUrl; $sourceFound = $true; break
                }
            }
            if (-not $sourceFound) { $logMessages += "    -> Source not found, marking as MANUAL."; $metadataToUpdate.source = 'MANUAL'; $metadataToUpdate.Remove('sourceUrl') }
        }

        $currentSourcePath = $metadataToUpdate.source
        if ($currentSourcePath -and $currentSourcePath -ne 'MANUAL' -and $currentSourcePath -ne 'DEPRECATED' -and (Test-Path $currentSourcePath)) {
            $actualFileTimestamp = (Get-Item $currentSourcePath).LastWriteTime.ToString("yyMMdd HH:mm:ss")
            if ($metadataToUpdate.sourceLastUpdated -ne $actualFileTimestamp) {
                $logMessages += "    -> Corrected sourceLastUpdated to '$actualFileTimestamp'"; $metadataToUpdate.sourceLastUpdated = $actualFileTimestamp
            }
        }
        elseif (-not $metadata.ContainsKey('sourceLastUpdated') -or [string]::IsNullOrWhiteSpace($metadata.sourceLastUpdated)) {
            $logMessages += "    -> Initialized empty sourceLastUpdated."; $metadataToUpdate.sourceLastUpdated = ""
        }

        if (-not $metadata.ContainsKey('sourceLastChangeFound') -or [string]::IsNullOrWhiteSpace($metadata.sourceLastChangeFound)) {
            $logMessages += "    -> Initialized sourceLastChangeFound to '$runTimestamp'"; $metadataToUpdate.sourceLastChangeFound = $runTimestamp
        }
    }

    if (-not $metadataToUpdate.ContainsKey('sourceState')) {
        if ($metadataToUpdate.source -eq 'MANUAL') { $metadataToUpdate.sourceState = 'manual' }
        else { $metadataToUpdate.sourceState = 'active' }
        $logMessages += "    -> Initialized sourceState to '$($metadataToUpdate.sourceState)'"
    }

    if ($null -ne (Compare-Object -ReferenceObject $metadata -DifferenceObject $metadataToUpdate -Property ($metadata.Keys + $metadataToUpdate.Keys | Select-Object -Unique))) {
        $wasModified = $true
    }

    if ($wasModified) {
        Write-Host "  - Updating '$($manifestFile.Name)'..." -ForegroundColor Green
        $logMessages | ForEach-Object { Write-Host $_ }
        $json = Set-CustomMetadata -JSONObject $json -MetadataToWrite $metadataToUpdate
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFile.FullName -Encoding UTF8
        $modifiedFileCount++
    }
}
Write-Host "`n✨ Seeding process complete. Modified $modifiedFileCount file(s)"
