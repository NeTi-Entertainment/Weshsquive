$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "annual_import_core.psm1"
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $Action
    }
    catch {
        return
    }

    throw $Message
}

$requiredFunctions = @(
    "Get-LatestSsmiRelease",
    "Get-LatestInseePopulationRelease",
    "Get-DvfReleases",
    "Get-DvfDepartmentUrls",
    "Get-LatestAnilRentRelease",
    "ConvertTo-AnnualYearArray",
    "New-AnnualImportPlan"
)
foreach ($name in $requiredFunctions) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    Assert-Equal -Actual ($null -ne $command) -Expected $true -Message "Annual import behavior '$name' should be available"
}

Assert-Equal -Actual (@(ConvertTo-AnnualYearArray -Value ([object[]]@())).Count) -Expected 0 -Message "An empty JSON-style array should remain empty"
Assert-Equal -Actual ((ConvertTo-AnnualYearArray -Value (,([object[]]@(2025, 2024, 2025)))) -join ",") -Expected "2024,2025" -Message "Nested JSON-style year arrays should be flattened, typed and deduplicated"

$ssmiDataset = [pscustomobject]@{
    resources = @(
        [pscustomobject]@{
            id = "communal-csv-gz"
            title = "COM - Base statistique communale de la délinquance enregistrée par la police et la gendarmerie nationales (fichier csv compressé)"
            format = "csv.gz"
            url = "https://static.data.gouv.fr/resources/ssmsi/20260709-115942/donnee-data.gouv-2025-geographie2026-produit-le2026-06-25.csv.gz"
            last_modified = "2026-07-09T13:59:52+02:00"
        },
        [pscustomobject]@{
            id = "untrusted-ssmi"
            title = "COM - Base statistique communale de la délinquance enregistrée par la police et la gendarmerie nationales (fichier csv compressé)"
            format = "csv.gz"
            url = "https://downloads.attacker.invalid/resources/ssmsi-2026-geographie2027-source.csv.gz"
            last_modified = "2027-07-09T13:59:52+02:00"
        },
        [pscustomobject]@{
            id = "complements"
            title = "COM COMPL - Base statistique communale (fichier complémentaire)"
            format = "xlsx"
            url = "https://static.data.gouv.fr/resources/ssmsi/complements.xlsx"
            last_modified = "2026-07-09T13:58:34+02:00"
        },
        [pscustomobject]@{
            id = "parquet"
            title = "COM - Base statistique communale (fichier parquet)"
            format = "parquet"
            url = "https://static.data.gouv.fr/resources/ssmsi/communes.parquet"
            last_modified = "2026-07-09T14:00:20+02:00"
        }
    )
}

$inseeOfficialTitle = "Populations de r$([char]0x00e9)f$([char]0x00e9)rence"
$inseeDataset = [pscustomobject]@{
    title = $inseeOfficialTitle
    organization = [pscustomobject]@{ name = "Institut national de la statistique et des études économiques (Insee)" }
    resources = @(
        [pscustomobject]@{
            id = "insee-population-csv"
            title = $inseeOfficialTitle
            url = "https://api.insee.fr/melodi/file/DS_POPULATIONS_REFERENCE/DS_POPULATIONS_REFERENCE_2023_CSV_FR"
            last_modified = "2026-05-29T08:59:41+02:00"
        },
        [pscustomobject]@{
            id = "insee-population-mirror"
            title = $inseeOfficialTitle
            url = "https://api-diffusion-catalogue-donnees-externe.insee.fr/file/DS_POPULATIONS_REFERENCE/DS_POPULATIONS_REFERENCE_2023_CSV_FR"
            last_modified = [datetime]::new(2026, 10, 9, 2, 1, 28, [datetimekind]::Local).AddMilliseconds(11)
        },
        [pscustomobject]@{
            id = "untrusted-population-resource"
            title = $inseeOfficialTitle
            url = "https://downloads.attacker.invalid/DS_POPULATIONS_REFERENCE_2027_CSV_FR"
            last_modified = "2027-01-01T00:00:00Z"
        }
    )
}

$unicodeInseeDataset = [pscustomobject]@{
    resources = @(
        [pscustomobject]@{
            id = "unicode-insee-population"
            title = $inseeOfficialTitle
            url = "https://api.insee.fr/melodi/file/DS_POPULATIONS_REFERENCE/DS_POPULATIONS_REFERENCE_2024_CSV_FR"
            last_modified = "2027-05-01T00:00:00Z"
        }
    )
}

$ssmiRelease = Get-LatestSsmiRelease -Dataset $ssmiDataset
Assert-Equal -Actual $ssmiRelease.Year -Expected 2025 -Message "The SSMSI release year should come from the communal CSV resource"
Assert-Equal -Actual $ssmiRelease.GeographyYear -Expected 2026 -Message "The SSMSI geography year should remain separate from the statistics year"
Assert-Equal -Actual $ssmiRelease.ResourceId -Expected "communal-csv-gz" -Message "The SSMSI catalog must not select complementary or Parquet resources"

$populationRelease = Get-LatestInseePopulationRelease -Dataset $inseeDataset
Assert-Equal -Actual $populationRelease.Year -Expected 2023 -Message "The Insee reference year should come from its resource identifier"
Assert-Equal -Actual $populationRelease.Url -Expected "https://api.insee.fr/melodi/file/DS_POPULATIONS_REFERENCE/DS_POPULATIONS_REFERENCE_2023_CSV_FR" -Message "The importer should use the reachable official Insee archive URL"
Assert-Equal -Actual $populationRelease.LastModified -Expected "2026-10-09T00:01:28.0110000Z" -Message "The Insee release should track the most recent official mirror revision while preferring the reachable source"
$unicodePopulationRelease = Get-LatestInseePopulationRelease -Dataset $unicodeInseeDataset
Assert-Equal -Actual $unicodePopulationRelease.Year -Expected 2024 -Message "The Insee selector should recognize the Unicode catalog title under Windows PowerShell"

$dvfDataset = [pscustomobject]@{
    organization = [pscustomobject]@{ slug = "data-gouv-fr" }
    last_modified = "2026-07-17T14:21:07.014Z"
    resources = @(
        [pscustomobject]@{
            id = "full-dvf"
            title = "DVF janvier 2021 - décembre 2025 - fichier unique"
            format = "csv.gz"
            url = "https://static.data.gouv.fr/resources/dvf/dvf.csv.gz"
            checksum = [pscustomobject]@{ type = "sha1"; value = "abc123" }
            last_modified = "2026-07-17T14:21:07.013Z"
        },
        [pscustomobject]@{
            id = "csv-root"
            title = "Donn$([char]0x00e9)es au format CSV"
            format = "url"
            url = "https://files.data.gouv.fr/geo-dvf/latest/csv/"
            last_modified = "2026-05-25T15:15:48Z"
        },
        [pscustomobject]@{
            id = "untrusted-root"
            title = "Donn$([char]0x00e9)es au format CSV"
            format = "url"
            url = "https://attacker.invalid/geo-dvf/latest/csv/"
            last_modified = "2027-01-01T00:00:00Z"
        }
    )
}

$dvfReleases = @(Get-DvfReleases -Dataset $dvfDataset)
Assert-Equal -Actual $dvfReleases.Count -Expected 5 -Message "DVF should expose every year from the official five-year resource"
Assert-Equal -Actual $dvfReleases[0].Year -Expected 2021 -Message "DVF releases should start at the year named by the full official resource"
Assert-Equal -Actual $dvfReleases[-1].Year -Expected 2025 -Message "DVF releases should include the latest official year"
Assert-Equal -Actual $dvfReleases[-1].BaseUrl -Expected "https://files.data.gouv.fr/geo-dvf/latest/csv/" -Message "DVF departmental URLs should use the trusted official CSV root"
Assert-Equal -Actual $dvfReleases[-1].LastModified -Expected "2026-07-17T14:21:07.0140000Z" -Message "DVF revisions should use a runtime-independent canonical UTC timestamp"
$dvfDepartmentUrls = @(Get-DvfDepartmentUrls -Release $dvfReleases[-1] -DepartmentCodes @("33", "57", "67", "68", "976", "2A", "971"))
Assert-Equal -Actual $dvfDepartmentUrls.Count -Expected 3 -Message "DVF URLs should omit Alsace, Moselle and Mayotte"
Assert-Equal -Actual $dvfDepartmentUrls[0] -Expected "https://files.data.gouv.fr/geo-dvf/latest/csv/2025/departements/2A.csv.gz" -Message "DVF should preserve alphanumeric department codes"
Assert-Equal -Actual $dvfDepartmentUrls[-1] -Expected "https://files.data.gouv.fr/geo-dvf/latest/csv/2025/departements/971.csv.gz" -Message "DVF should include covered overseas departments"

$anilCatalog = [pscustomobject]@{
    data = @(
        [pscustomobject]@{
            title = '"Carte des loyers" - Indicateurs de loyers d''annonce par commune en 2024'
            organization = [pscustomobject]@{ slug = "ministere-de-la-transition-ecologique" }
            last_modified = "2024-12-01T00:00:00Z"
            resources = @(
                [pscustomobject]@{ id = "a24"; title = "Indicateurs de loyer appartement"; format = "csv"; url = "https://static.data.gouv.fr/resources/rents-2024/apartment.csv"; last_modified = "2024-12-01T00:00:00Z" },
                [pscustomobject]@{ id = "h24"; title = "Indicateurs de loyer maison"; format = "csv"; url = "https://static.data.gouv.fr/resources/rents-2024/house.csv"; last_modified = "2024-12-01T00:00:00Z" }
            )
        },
        [pscustomobject]@{
            title = '"Carte des loyers" - Indicateurs de loyers d''annonce par commune en 2025'
            organization = [pscustomobject]@{ slug = "ministere-de-la-transition-ecologique" }
            last_modified = "2025-12-11T14:58:19Z"
            resources = @(
                [pscustomobject]@{ id = "a25"; title = "Indicateurs de loyer appartement"; format = "csv"; url = "https://static.data.gouv.fr/resources/rents-2025/apartment.csv"; last_modified = "2025-12-11T14:50:11Z" },
                [pscustomobject]@{ id = "a25-small"; title = "Indicateur de loyer appartement de 1 ou 2 pièces"; format = "csv"; url = "https://static.data.gouv.fr/resources/rents-2025/apartment-small.csv"; last_modified = "2025-12-11T14:49:35Z" },
                [pscustomobject]@{ id = "h25"; title = "Indicateurs de loyer maison"; format = "csv"; url = "https://static.data.gouv.fr/resources/rents-2025/house.csv"; last_modified = "2025-12-11T14:50:40Z" }
            )
        },
        [pscustomobject]@{
            title = '"Carte des loyers" - Indicateurs de loyers d''annonce par commune en 2026'
            organization = [pscustomobject]@{ slug = "unknown-publisher" }
            last_modified = "2026-12-01T00:00:00Z"
            resources = @()
        }
    )
}

$anilRelease = Get-LatestAnilRentRelease -Catalog $anilCatalog
Assert-Equal -Actual $anilRelease.Year -Expected 2025 -Message "ANIL should select the latest complete official publication"
Assert-Equal -Actual $anilRelease.ApartmentResourceId -Expected "a25" -Message "ANIL should select all-apartment data, not bedroom subtypes"
Assert-Equal -Actual $anilRelease.HouseResourceId -Expected "h25" -Message "ANIL should select the house resource"
Assert-Equal -Actual $anilRelease.LastModified -Expected "2025-12-11T14:58:19.0000000Z" -Message "ANIL revisions should use a runtime-independent canonical UTC timestamp"
Assert-Equal -Actual $anilRelease.ManifestHash.Length -Expected 64 -Message "ANIL discovery should fingerprint both official resources"

$plan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2024 `
    -ImportedCrimeUrl "https://static.data.gouv.fr/previous.csv.gz" `
    -ImportedCrimeLastModified "2025-07-01T00:00:00+02:00" `
    -ImportedPopulationYear 2022 `
    -ImportedPopulationUrl "https://www.insee.fr/previous.zip" `
    -ImportedPopulationLastModified "2024-12-01T00:00:00+01:00"
Assert-Equal -Actual $plan.ImportCrime -Expected $true -Message "A newer SSMSI year should be scheduled"
Assert-Equal -Actual $plan.ImportPopulation -Expected $true -Message "A newer Insee reference year should be scheduled"

$unchangedPlan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2025 `
    -ImportedCrimeUrl $ssmiRelease.Url `
    -ImportedCrimeLastModified $ssmiRelease.LastModified `
    -ImportedPopulationYear 2023 `
    -ImportedPopulationUrl $populationRelease.Url `
    -ImportedPopulationLastModified $populationRelease.LastModified `
    -MetricsSnapshotAt "2026-10-09T10:00:00Z" `
    -LatestMetricsImportAt "2026-10-09T10:00:00Z"
Assert-Equal -Actual $unchangedPlan.HasUpdates -Expected $false -Message "A matching year and source URL should be a no-op"
Assert-Equal -Actual $unchangedPlan.RefreshMetrics -Expected $false -Message "An active snapshot at least as new as imported data should not rebuild monthly"

$staleMetricsPlan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2025 `
    -ImportedCrimeUrl $ssmiRelease.Url `
    -ImportedCrimeLastModified $ssmiRelease.LastModified `
    -ImportedPopulationYear 2023 `
    -ImportedPopulationUrl $populationRelease.Url `
    -ImportedPopulationLastModified $populationRelease.LastModified `
    -MetricsSnapshotAt "2026-10-08T10:00:00Z" `
    -LatestMetricsImportAt "2026-10-09T10:00:00Z"
Assert-Equal -Actual $staleMetricsPlan.ImportCrime -Expected $false -Message "Fresh raw releases should not be reimported just because metrics are stale"
Assert-Equal -Actual $staleMetricsPlan.RefreshMetrics -Expected $true -Message "A failed metrics refresh should be retried on the next scheduled check"
Assert-Equal -Actual $staleMetricsPlan.HasUpdates -Expected $true -Message "A stale active metrics snapshot should schedule a refresh"

$replacementPlan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2025 `
    -ImportedCrimeUrl "https://static.data.gouv.fr/previous-edition.csv.gz" `
    -ImportedCrimeLastModified $ssmiRelease.LastModified `
    -ImportedPopulationYear 2023 `
    -ImportedPopulationUrl "https://www.insee.fr/previous-edition.zip" `
    -ImportedPopulationLastModified $populationRelease.LastModified
Assert-Equal -Actual $replacementPlan.ImportCrime -Expected $true -Message "A revised source URL for the latest SSMSI year should be imported"
Assert-Equal -Actual $replacementPlan.ImportPopulation -Expected $true -Message "A revised source URL for the latest Insee year should be imported"

$revisionPlan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2025 `
    -ImportedCrimeUrl $ssmiRelease.Url `
    -ImportedCrimeLastModified "2026-07-01T00:00:00+02:00" `
    -ImportedPopulationYear 2023 `
    -ImportedPopulationUrl $populationRelease.Url `
    -ImportedPopulationLastModified "2026-05-01T00:00:00+02:00"
Assert-Equal -Actual $revisionPlan.HasUpdates -Expected $true -Message "A catalog revision with the same year and URL should be imported"

Assert-Throws -Action { Get-LatestSsmiRelease -Dataset ([pscustomobject]@{ resources = @() }) } -Message "Missing SSMSI resources should fail closed"
Assert-Throws -Action { Get-LatestInseePopulationRelease -Dataset ([pscustomobject]@{ resources = @() }) } -Message "Missing Insee resources should fail closed"

$propertyPlan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2025 `
    -ImportedCrimeUrl $ssmiRelease.Url `
    -ImportedCrimeLastModified $ssmiRelease.LastModified `
    -ImportedPopulationYear 2023 `
    -ImportedPopulationUrl $populationRelease.Url `
    -ImportedPopulationLastModified $populationRelease.LastModified `
    -DvfReleases $dvfReleases `
    -ImportedDvfManifestByYear @{ "2021" = $dvfReleases[0].ManifestHash; "2022" = "old-revision"; "2023" = $dvfReleases[2].ManifestHash; "2024" = $dvfReleases[3].ManifestHash; "2025" = $dvfReleases[4].ManifestHash } `
    -AnilRentRelease $anilRelease `
    -ImportedRentYear 2024 `
    -ImportedRentApartmentUrl "https://static.data.gouv.fr/resources/rents-2024/apartment.csv" `
    -ImportedRentLastModified "2024-12-01T00:00:00Z" `
    -ImportedRentCatalogManifestHash "previous-anil-release" `
    -PropertyMetricMissingYears @(2023)
Assert-Equal -Actual (($propertyPlan.ImportDvfYears -join ",")) -Expected "2022" -Message "Only a revised DVF year should be planned"
Assert-Equal -Actual $propertyPlan.ImportRentYear -Expected 2025 -Message "The latest ANIL year should be planned"
Assert-Equal -Actual (($propertyPlan.RefreshPropertyMarketYears -join ",")) -Expected "2023" -Message "Missing property metrics should be refreshed independently"
Assert-Equal -Actual $propertyPlan.HasUpdates -Expected $true -Message "Property releases should make the annual plan actionable"

$unchangedPropertyPlan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2025 `
    -ImportedCrimeUrl $ssmiRelease.Url `
    -ImportedCrimeLastModified $ssmiRelease.LastModified `
    -ImportedPopulationYear 2023 `
    -ImportedPopulationUrl $populationRelease.Url `
    -ImportedPopulationLastModified $populationRelease.LastModified `
    -MetricsSnapshotAt "2026-10-09T10:00:00Z" `
    -LatestMetricsImportAt "2026-10-09T10:00:00Z" `
    -DvfReleases $dvfReleases `
    -ImportedDvfManifestByYear @{ "2021" = $dvfReleases[0].ManifestHash; "2022" = $dvfReleases[1].ManifestHash; "2023" = $dvfReleases[2].ManifestHash; "2024" = $dvfReleases[3].ManifestHash; "2025" = $dvfReleases[4].ManifestHash } `
    -AnilRentRelease $anilRelease `
    -ImportedRentYear 2025 `
    -ImportedRentApartmentUrl $anilRelease.ApartmentUrl `
    -ImportedRentLastModified $anilRelease.LastModified `
    -ImportedRentCatalogManifestHash $anilRelease.ManifestHash
Assert-Equal -Actual $unchangedPropertyPlan.HasUpdates -Expected $false -Message "Matching property revisions should remain a no-op"

$revisedAnilCatalog = $anilCatalog | ConvertTo-Json -Depth 8 | ConvertFrom-Json
($revisedAnilCatalog.data | Where-Object title -match '2025$').resources |
    Where-Object title -eq "Indicateurs de loyer maison" |
    ForEach-Object { $_.url = "https://static.data.gouv.fr/resources/rents-2025/house-revised.csv" }
$revisedAnilRelease = Get-LatestAnilRentRelease -Catalog $revisedAnilCatalog
if ($revisedAnilRelease.ManifestHash -eq $anilRelease.ManifestHash) {
    throw "Changing only the official ANIL house resource should change the release fingerprint."
}
$houseRevisionPlan = New-AnnualImportPlan `
    -SsmiRelease $ssmiRelease `
    -PopulationRelease $populationRelease `
    -ImportedCrimeYear 2025 -ImportedCrimeUrl $ssmiRelease.Url -ImportedCrimeLastModified $ssmiRelease.LastModified `
    -ImportedPopulationYear 2023 -ImportedPopulationUrl $populationRelease.Url -ImportedPopulationLastModified $populationRelease.LastModified `
    -AnilRentRelease $revisedAnilRelease `
    -ImportedRentYear 2025 `
    -ImportedRentApartmentUrl $anilRelease.ApartmentUrl `
    -ImportedRentLastModified $anilRelease.LastModified `
    -ImportedRentCatalogManifestHash $anilRelease.ManifestHash
Assert-Equal -Actual $houseRevisionPlan.ImportRentYear -Expected 2025 -Message "A house-only ANIL resource revision should be imported"

Assert-Throws -Action { Get-DvfReleases -Dataset ([pscustomobject]@{ organization = [pscustomobject]@{ slug = "unknown" }; resources = @() }) } -Message "Untrusted DVF catalogs should fail closed"
Assert-Throws -Action { Get-LatestAnilRentRelease -Catalog ([pscustomobject]@{ data = @() }) } -Message "Missing ANIL publications should fail closed"

Write-Host "Annual import core test passed."
