Set-StrictMode -Version Latest

function ConvertTo-CatalogTimestamp {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }
    if ($Value -is [datetimeoffset]) {
        return $Value.UtcDateTime.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    }

    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed
        )) {
        return $parsed.UtcDateTime.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Get-LatestSsmiRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Dataset)

    $candidates = @(
        $Dataset.resources |
            Where-Object {
                $_.format -eq "csv.gz" `
                    -and $_.title -match '^COM\s+-\s+Base statistique communale' `
                    -and $_.title -notmatch '^COM COMPL' `
                    -and $_.url -match '^https://static\.data\.gouv\.fr/'
            } |
            ForEach-Object {
                $match = [regex]::Match(
                    [string]$_.url,
                    '-(?<year>20\d{2})-geographie(?<geographyYear>20\d{2})-'
                )
                if (-not $match.Success) {
                    return
                }

                [pscustomobject]@{
                    Year = [int]$match.Groups["year"].Value
                    GeographyYear = [int]$match.Groups["geographyYear"].Value
                    ResourceId = [string]$_.id
                    Title = [string]$_.title
                    Format = [string]$_.format
                    Url = [string]$_.url
                    LastModified = ConvertTo-CatalogTimestamp -Value $_.last_modified
                }
            }
    )

    if ($candidates.Count -eq 0) {
        throw "The official SSMSI catalog has no compatible communal CSV resource with a recognized year. No import was started."
    }

    return $candidates |
        Sort-Object Year, LastModified -Descending |
        Select-Object -First 1
}

function Get-LatestInseePopulationRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Dataset)

    $officialTitle = "Populations de r{0}f{0}rence" -f [char]0x00e9
    $candidates = @(
        $Dataset.resources |
            Where-Object { $_.title -eq $officialTitle } |
            ForEach-Object {
                $match = [regex]::Match(
                    [string]$_.url,
                    '^https://(?:api\.insee\.fr/melodi|api-diffusion-catalogue-donnees-externe\.insee\.fr)/file/DS_POPULATIONS_REFERENCE/DS_POPULATIONS_REFERENCE_(?<year>20\d{2})_CSV_FR/?$'
                )
                if (-not $match.Success) {
                    return
                }

                [pscustomobject]@{
                    Year = [int]$match.Groups["year"].Value
                    ResourceId = [string]$_.id
                    Title = [string]$_.title
                    Url = [string]$_.url
                    LastModified = ConvertTo-CatalogTimestamp -Value $_.last_modified
                    PreferredSource = [string]$_.url -match '^https://api\.insee\.fr/'
                }
            }
    )

    if ($candidates.Count -eq 0) {
        throw "The official Insee catalog has no compatible reference-population CSV archive. No import was started."
    }

    $latestYear = ($candidates | Measure-Object -Property Year -Maximum).Maximum
    $yearCandidates = @($candidates | Where-Object Year -eq $latestYear)
    $preferred = $yearCandidates |
        Sort-Object PreferredSource -Descending |
        Select-Object -First 1
    $latestRevision = $yearCandidates |
        Sort-Object LastModified -Descending |
        Select-Object -First 1

    $preferred.LastModified = $latestRevision.LastModified
    return $preferred
}

function Get-DvfReleases {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Dataset)

    if ($Dataset.organization.slug -ne "data-gouv-fr") {
        throw "The DVF geolocated catalog is not published by data.gouv.fr. No import was started."
    }

    $officialCsvTitle = "Donn{0}es au format CSV" -f [char]0x00e9
    $csvRoot = $Dataset.resources |
        Where-Object {
            $_.title -eq $officialCsvTitle `
                -and $_.url -eq "https://files.data.gouv.fr/geo-dvf/latest/csv/"
        } |
        Select-Object -First 1
    $fullResource = $Dataset.resources |
        Where-Object {
            $_.format -eq "csv.gz" `
                -and $_.title -match '^DVF\s+.*20\d{2}.*20\d{2}.*fichier unique$' `
                -and $_.url -match '^https://static\.data\.gouv\.fr/'
        } |
        Select-Object -First 1

    if ($null -eq $csvRoot -or $null -eq $fullResource) {
        throw "The official DVF catalog has no trusted CSV root and five-year resource. No import was started."
    }

    $yearMatches = @([regex]::Matches([string]$fullResource.title, '20\d{2}') | ForEach-Object { [int]$_.Value })
    if ($yearMatches.Count -lt 2) {
        throw "The official DVF resource title does not expose its year range. No import was started."
    }
    $firstYear = ($yearMatches | Measure-Object -Minimum).Minimum
    $lastYear = ($yearMatches | Measure-Object -Maximum).Maximum
    if ($lastYear -lt $firstYear -or ($lastYear - $firstYear) -gt 10) {
        throw "The official DVF year range is invalid. No import was started."
    }

    $revision = ConvertTo-CatalogTimestamp -Value $Dataset.last_modified
    $checksum = if ($null -ne $fullResource.checksum) { [string]$fullResource.checksum.value } else { "" }
    for ($year = $firstYear; $year -le $lastYear; $year++) {
        $material = "$year|$($csvRoot.url)|$revision|$checksum"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $manifestHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }

        [pscustomobject]@{
            Year = $year
            BaseUrl = [string]$csvRoot.url
            LastModified = $revision
            ManifestHash = $manifestHash
            FullResourceId = [string]$fullResource.id
        }
    }
}

function Get-LatestAnilRentRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Catalog)

    $datasets = if ($null -ne $Catalog.data) { @($Catalog.data) } elseif ($null -ne $Catalog.results) { @($Catalog.results) } else { @() }
    $candidates = foreach ($dataset in $datasets) {
        if ($dataset.organization.slug -ne "ministere-de-la-transition-ecologique") { continue }
        $yearMatch = [regex]::Match([string]$dataset.title, "commune en (?<year>20\d{2})$")
        if (-not $yearMatch.Success) { continue }

        $apartment = $dataset.resources |
            Where-Object {
                $_.title -eq "Indicateurs de loyer appartement" `
                    -and $_.format -eq "csv" `
                    -and $_.url -match '^https://static\.data\.gouv\.fr/'
            } |
            Select-Object -First 1
        $house = $dataset.resources |
            Where-Object {
                $_.title -eq "Indicateurs de loyer maison" `
                    -and $_.format -eq "csv" `
                    -and $_.url -match '^https://static\.data\.gouv\.fr/'
            } |
            Select-Object -First 1
        if ($null -eq $apartment -or $null -eq $house) { continue }

        $timestamps = @(
            ConvertTo-CatalogTimestamp -Value $dataset.last_modified
            ConvertTo-CatalogTimestamp -Value $apartment.last_modified
            ConvertTo-CatalogTimestamp -Value $house.last_modified
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $lastModified = $timestamps | Sort-Object -Descending | Select-Object -First 1
        $apartmentLastModified = ConvertTo-CatalogTimestamp -Value $apartment.last_modified
        $houseLastModified = ConvertTo-CatalogTimestamp -Value $house.last_modified
        $apartmentChecksumProperty = $apartment.PSObject.Properties["checksum"]
        $houseChecksumProperty = $house.PSObject.Properties["checksum"]
        $apartmentChecksum = if ($null -ne $apartmentChecksumProperty -and $null -ne $apartmentChecksumProperty.Value) {
            [string]$apartmentChecksumProperty.Value.value
        } else { "" }
        $houseChecksum = if ($null -ne $houseChecksumProperty -and $null -ne $houseChecksumProperty.Value) {
            [string]$houseChecksumProperty.Value.value
        } else { "" }
        $manifestMaterial = @(
            [string]$yearMatch.Groups["year"].Value,
            [string]$apartment.id, [string]$apartment.url, $apartmentLastModified, $apartmentChecksum,
            [string]$house.id, [string]$house.url, $houseLastModified, $houseChecksum
        ) -join "|"
        $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestMaterial)
        $manifestSha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $manifestHash = ([BitConverter]::ToString($manifestSha.ComputeHash($manifestBytes))).Replace("-", "").ToLowerInvariant()
        }
        finally { $manifestSha.Dispose() }

        [pscustomobject]@{
            Year = [int]$yearMatch.Groups["year"].Value
            ApartmentResourceId = [string]$apartment.id
            ApartmentUrl = [string]$apartment.url
            HouseResourceId = [string]$house.id
            HouseUrl = [string]$house.url
            LastModified = [string]$lastModified
            ApartmentLastModified = $apartmentLastModified
            HouseLastModified = $houseLastModified
            ApartmentChecksum = $apartmentChecksum
            HouseChecksum = $houseChecksum
            ManifestHash = $manifestHash
        }
    }

    if (@($candidates).Count -eq 0) {
        throw "The official ANIL catalog has no complete communal apartment and house release. No import was started."
    }

    return $candidates | Sort-Object Year, LastModified -Descending | Select-Object -First 1
}

function Get-DvfDepartmentUrls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Release,
        [Parameter(Mandatory = $true)][string[]]$DepartmentCodes
    )

    if ($Release.BaseUrl -ne "https://files.data.gouv.fr/geo-dvf/latest/csv/") {
        throw "The DVF release does not use the trusted departmental CSV root."
    }

    $DepartmentCodes |
        Where-Object { $_ -notin @("57", "67", "68", "976") } |
        Sort-Object -Unique |
        ForEach-Object { "$($Release.BaseUrl)$($Release.Year)/departements/$_.csv.gz" }
}

function ConvertTo-AnnualYearArray {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $years = [System.Collections.Generic.List[int]]::new()
    function Add-YearValue {
        param([AllowNull()][object]$Item)

        if ($null -eq $Item) { return }
        if ($Item -is [System.Collections.IEnumerable] -and $Item -isnot [string]) {
            foreach ($nestedItem in $Item) { Add-YearValue -Item $nestedItem }
            return
        }

        $parsed = 0
        if (-not [int]::TryParse([string]$Item, [ref]$parsed) -or $parsed -lt 2000 -or $parsed -gt 2100) {
            throw "Invalid annual import year '$Item'."
        }
        $years.Add($parsed)
    }

    Add-YearValue -Item $Value
    return @($years | Sort-Object -Unique)
}

function New-AnnualImportPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$SsmiRelease,
        [Parameter(Mandatory = $true)][object]$PopulationRelease,
        [int]$ImportedCrimeYear = 0,
        [string]$ImportedCrimeUrl = "",
        [string]$ImportedCrimeLastModified = "",
        [int]$ImportedPopulationYear = 0,
        [string]$ImportedPopulationUrl = "",
        [string]$ImportedPopulationLastModified = "",
        [string]$MetricsSnapshotAt = "",
        [string]$LatestMetricsImportAt = "",
        [object[]]$DvfReleases = @(),
        [hashtable]$ImportedDvfManifestByYear = @{},
        [AllowNull()][object]$AnilRentRelease = $null,
        [int]$ImportedRentYear = 0,
        [string]$ImportedRentApartmentUrl = "",
        [string]$ImportedRentLastModified = "",
        [string]$ImportedRentCatalogManifestHash = "",
        [int[]]$PropertyMetricMissingYears = @()
    )

    $importCrime = $SsmiRelease.Year -gt $ImportedCrimeYear `
        -or ($SsmiRelease.Year -eq $ImportedCrimeYear `
            -and ($SsmiRelease.Url -ne $ImportedCrimeUrl `
                -or $SsmiRelease.LastModified -ne $ImportedCrimeLastModified))
    $importPopulation = $PopulationRelease.Year -gt $ImportedPopulationYear `
        -or ($PopulationRelease.Year -eq $ImportedPopulationYear `
            -and ($PopulationRelease.Url -ne $ImportedPopulationUrl `
                -or $PopulationRelease.LastModified -ne $ImportedPopulationLastModified))
    $refreshMetrics = $false
    if (-not [string]::IsNullOrWhiteSpace($LatestMetricsImportAt)) {
        $latestImportTime = [datetimeoffset]::MinValue
        $snapshotTime = [datetimeoffset]::MinValue
        $hasImportTime = [datetimeoffset]::TryParse($LatestMetricsImportAt, [ref]$latestImportTime)
        $hasSnapshotTime = [datetimeoffset]::TryParse($MetricsSnapshotAt, [ref]$snapshotTime)
        $refreshMetrics = -not $hasImportTime -or -not $hasSnapshotTime -or $snapshotTime -lt $latestImportTime
    }

    $importDvfYears = @(
        $DvfReleases |
            Where-Object {
                $key = [string]$_.Year
                -not $ImportedDvfManifestByYear.ContainsKey($key) `
                    -or $ImportedDvfManifestByYear[$key] -ne $_.ManifestHash
            } |
            ForEach-Object { [int]$_.Year } |
            Sort-Object -Unique
    )
    $importRentYear = 0
    if ($null -ne $AnilRentRelease) {
        if (
            $AnilRentRelease.Year -gt $ImportedRentYear `
                -or ($AnilRentRelease.Year -eq $ImportedRentYear `
                    -and ($AnilRentRelease.ApartmentUrl -ne $ImportedRentApartmentUrl `
                        -or $AnilRentRelease.LastModified -ne $ImportedRentLastModified `
                        -or $AnilRentRelease.ManifestHash -ne $ImportedRentCatalogManifestHash))
        ) {
            $importRentYear = [int]$AnilRentRelease.Year
        }
    }
    $refreshPropertyMarketYears = @($PropertyMetricMissingYears | Sort-Object -Unique)

    [pscustomobject]@{
        ImportCrime = [bool]$importCrime
        ImportPopulation = [bool]$importPopulation
        RefreshBoundaries = [bool]($importCrime -or $importPopulation)
        RefreshMetrics = [bool]$refreshMetrics
        ImportDvfYears = $importDvfYears
        ImportRentYear = $importRentYear
        RefreshPropertyMarketYears = $refreshPropertyMarketYears
        HasUpdates = [bool](
            $importCrime -or $importPopulation -or $refreshMetrics `
                -or $importDvfYears.Count -gt 0 `
                -or $importRentYear -gt 0 `
                -or $refreshPropertyMarketYears.Count -gt 0
        )
    }
}

Export-ModuleMember -Function Get-LatestSsmiRelease, Get-LatestInseePopulationRelease, Get-DvfReleases, Get-DvfDepartmentUrls, Get-LatestAnilRentRelease, ConvertTo-AnnualYearArray, New-AnnualImportPlan
