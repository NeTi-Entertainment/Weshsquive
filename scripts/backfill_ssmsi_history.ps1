[CmdletBinding()]
param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$SsmiDatasetApiUrl = "https://www.data.gouv.fr/api/1/datasets/bases-statistiques-communale-departementale-et-regionale-de-la-delinquance-enregistree-par-la-police-et-la-gendarmerie-nationales/",
    [string]$CrimeFileUrl = "",
    [int[]]$Years = (2016..2024),
    [string]$Source = "ssmsi-base-communale",
    [string]$SourceLastModified = "",
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) { $DatabaseName = "app_criminalite" }
if ([string]::IsNullOrWhiteSpace($DatabaseUser)) { $DatabaseUser = "app" }
if ([string]::IsNullOrWhiteSpace($DatabasePassword)) { $DatabasePassword = "app_dev_password" }
if ($Years.Count -eq 0) { throw "Select at least one historical SSMSI year." }
if ($Years.Count -ne @($Years | Sort-Object -Unique).Count) { throw "Historical SSMSI years must be unique." }
if ($Years | Where-Object { $_ -lt 2016 -or $_ -gt 2024 }) {
    throw "Historical backfill years must be within 2016-2024. Annual imports use scripts/import_crime_data_ssmsi.ps1 instead."
}
$Years = @($Years | Sort-Object)

$coreModulePath = Join-Path $PSScriptRoot "annual_import_core.psm1"
Import-Module $coreModulePath -Force

if ([string]::IsNullOrWhiteSpace($CrimeFileUrl)) {
    $dataset = Invoke-RestMethod -Uri $SsmiDatasetApiUrl -Method Get -TimeoutSec 45
    $release = Get-LatestSsmiRelease -Dataset $dataset
    $CrimeFileUrl = $release.Url
    if ([string]::IsNullOrWhiteSpace($SourceLastModified)) {
        $SourceLastModified = $release.LastModified
    }
}

if ($PlanOnly) {
    Write-Host "SSMSI historical backfill plan: years=$($Years -join ','); source=$CrimeFileUrl; system=$Source"
    return
}

$importArguments = @{
    ContainerName = $ContainerName
    DatabaseName = $DatabaseName
    DatabaseUser = $DatabaseUser
    DatabasePassword = $DatabasePassword
    CrimeFileUrl = $CrimeFileUrl
    Years = $Years
    Source = $Source
    SourceLastModified = $SourceLastModified
    DeferMetricsRefresh = $true
}
if ($null -ne $release) { $importArguments.GeographyYear = $release.GeographyYear }

try {
    & (Join-Path $PSScriptRoot "import_crime_data_ssmsi.ps1") @importArguments
    if ($LASTEXITCODE -ne 0) { throw "SSMSI historical importer exited with code $LASTEXITCODE." }
}
catch {
    throw "SSMSI historical import failed; no search-metric refresh was attempted. Details: $($_.Exception.Message)"
}

try {
    & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser $DatabaseUser `
        -DatabasePassword $DatabasePassword
    if ($LASTEXITCODE -ne 0) { throw "Search metric refresh exited with code $LASTEXITCODE." }
}
catch {
    throw "SSMSI historical data was committed, but the previous search-metric snapshot remains active. Retry scripts/refresh_search_metrics.ps1. Details: $($_.Exception.Message)"
}

Write-Host "SSMSI historical backfill completed for years $($Years -join ', ')."
