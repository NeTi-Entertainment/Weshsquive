[CmdletBinding()]
param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$SsmiDatasetApiUrl = "https://www.data.gouv.fr/api/1/datasets/bases-statistiques-communale-departementale-et-regionale-de-la-delinquance-enregistree-par-la-police-et-la-gendarmerie-nationales/",
    [string]$PopulationDatasetApiUrl = "https://www.data.gouv.fr/api/1/datasets/populations-de-reference/",
    [string]$DvfDatasetApiUrl = "https://www.data.gouv.fr/api/1/datasets/demandes-de-valeurs-foncieres-geolocalisees/",
    [string]$AnilCatalogApiUrl = "https://www.data.gouv.fr/api/1/datasets/?q=carte%20des%20loyers%20indicateurs%20de%20loyers%20annonce%20par%20commune&page_size=20",
    [string]$LogDirectory,
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) { $DatabaseName = "app_criminalite" }
if ([string]::IsNullOrWhiteSpace($DatabaseUser)) { $DatabaseUser = "app" }
if ([string]::IsNullOrWhiteSpace($DatabasePassword)) { $DatabasePassword = "app_dev_password" }
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $baseLogDirectory = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $HOME } else { $env:LOCALAPPDATA }
    $LogDirectory = Join-Path $baseLogDirectory "AppCriminalite\logs"
}

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$logPath = Join-Path $LogDirectory ("annual-import-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
$coreModulePath = Join-Path $PSScriptRoot "annual_import_core.psm1"
Import-Module $coreModulePath -Force

function Write-AnnualLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $entry = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"), $Message
    Write-Host $entry
    [System.IO.File]::AppendAllText(
        $logPath,
        $entry + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-ImportedSourceState {
    $sql = @'
select json_build_object(
    'crimeYear', coalesce((select max(year)::integer from crime_stats where source = 'ssmsi-base-communale'), 0),
    'crimeUrl', coalesce((
        select source_url
        from import_batches
        where source_system = 'ssmsi-base-communale'
            and source_year = (select max(year) from crime_stats where source = 'ssmsi-base-communale')
        order by completed_at desc nulls last, id desc
        limit 1
    ), ''),
    'crimeLastModified', coalesce((
        select metadata->>'catalogLastModified'
        from import_batches
        where source_system = 'ssmsi-base-communale'
            and source_year = (select max(year) from crime_stats where source = 'ssmsi-base-communale')
        order by completed_at desc nulls last, id desc
        limit 1
    ), ''),
    'populationYear', coalesce((select max(year)::integer from population_history where source = 'insee-populations-reference'), 0),
    'populationUrl', coalesce((
        select source_url
        from import_batches
        where source_system = 'insee-populations-reference'
            and source_year = (select max(year) from population_history where source = 'insee-populations-reference')
        order by completed_at desc nulls last, id desc
        limit 1
    ), ''),
    'populationLastModified', coalesce((
        select metadata->>'catalogLastModified'
        from import_batches
        where source_system = 'insee-populations-reference'
            and source_year = (select max(year) from population_history where source = 'insee-populations-reference')
        order by completed_at desc nulls last, id desc
        limit 1
    ), ''),
    'metricsSnapshotAt', coalesce((
        select snapshot.created_at::text
        from search_metrics_active active
        join search_metric_snapshots snapshot using (snapshot_id)
        where active.singleton
    ), ''),
    'latestMetricsImportAt', coalesce((
        select max(completed_at)::text
        from import_batches
        where source_system in ('ssmsi-base-communale', 'insee-populations-reference')
            and status = 'completed'
    ), ''),
    'dvfManifestByYear', coalesce((
        select jsonb_object_agg(source_year::text, manifest_hash)
        from (
            select distinct on (source_year)
                source_year,
                coalesce(metadata->>'catalogManifestHash', metadata->>'manifestHash', '') as manifest_hash
            from import_batches
            where source_system = 'dvf-geolocated'
                and status = 'completed'
            order by source_year, completed_at desc nulls last, id desc
        ) latest_dvf
    ), '{}'::jsonb),
    'rentYear', coalesce((
        select source_year::integer
        from import_batches
        where source_system = 'anil-rent-map'
            and status = 'completed'
        order by source_year desc, completed_at desc nulls last, id desc
        limit 1
    ), 0),
    'rentApartmentUrl', coalesce((
        select metadata->>'apartmentFileUrl'
        from import_batches
        where source_system = 'anil-rent-map'
            and status = 'completed'
        order by source_year desc, completed_at desc nulls last, id desc
        limit 1
    ), ''),
    'rentLastModified', coalesce((
        select metadata->>'catalogLastModified'
        from import_batches
        where source_system = 'anil-rent-map'
            and status = 'completed'
        order by source_year desc, completed_at desc nulls last, id desc
        limit 1
    ), ''),
    'rentCatalogManifestHash', coalesce((
        select metadata->>'catalogManifestHash'
        from import_batches
        where source_system = 'anil-rent-map'
            and status = 'completed'
        order by source_year desc, completed_at desc nulls last, id desc
        limit 1
    ), '')
)::text;
'@

    $output = & docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -q -t -A -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the latest imported years from PostgreSQL: $($output -join ' ')"
    }

    $json = ($output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "PostgreSQL returned no import state."
    }

    $state = $json | ConvertFrom-Json
    $state | Add-Member -NotePropertyName propertyMetricMissingYears -NotePropertyValue @()

    $hasPropertyTablesSql = @'
select (
    to_regclass('public.property_sale_observations') is not null
    and to_regclass('public.property_rent_observations') is not null
    and to_regclass('public.property_market_metrics') is not null
)::text;
'@
    $hasPropertyTablesOutput = & docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -q -t -A -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c $hasPropertyTablesSql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the property-market schema in PostgreSQL: $($hasPropertyTablesOutput -join ' ')"
    }

    if (($hasPropertyTablesOutput -join "`n").Trim() -eq "true") {
        $missingPropertyMetricsSql = @'
with imported_years as (
    select source_year::integer as year, 'sale'::text as metric_kind
    from property_sale_observations
    where source_system = 'dvf-geolocated'
    group by source_year
    union all
    select source_year::integer as year, 'rent'::text as metric_kind
    from property_rent_observations
    where source_system = 'anil-rent-map'
    group by source_year
), missing as (
    select distinct imported.year
    from imported_years imported
    where not exists (
        select 1
        from property_market_metrics metric
        where metric.year = imported.year
            and metric.metric_kind = imported.metric_kind
    )
)
select coalesce(json_agg(year order by year), '[]'::json)::text from missing;
'@
        $missingOutput = & docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
            psql -q -t -A -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c $missingPropertyMetricsSql 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not inspect property-market metrics in PostgreSQL: $($missingOutput -join ' ')"
        }
        $parsedMissingYears = ($missingOutput -join "`n").Trim() | ConvertFrom-Json
        $state.propertyMetricMissingYears = @(ConvertTo-AnnualYearArray -Value $parsedMissingYears)
    }

    return $state
}

function Get-DepartmentCodes {
    $sql = "select code from departments order by code;"
    $output = & docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -q -t -A -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read department codes from PostgreSQL: $($output -join ' ')"
    }

    return @($output | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Invoke-ImportStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Arguments
    )

    Write-AnnualLog "Début : $Name"
    & $Path @Arguments
    Write-AnnualLog "Terminé : $Name"
}

try {
    Write-AnnualLog "Vérification des catalogues officiels."
    $ssmiDataset = Invoke-RestMethod -Uri $SsmiDatasetApiUrl -Method Get -TimeoutSec 45
    $populationDataset = Invoke-RestMethod -Uri $PopulationDatasetApiUrl -Method Get -TimeoutSec 45
    $ssmiRelease = Get-LatestSsmiRelease -Dataset $ssmiDataset
    $populationRelease = Get-LatestInseePopulationRelease -Dataset $populationDataset
    $propertyErrors = [System.Collections.Generic.List[string]]::new()
    $dvfReleases = @()
    $anilRelease = $null
    try {
        $dvfDataset = Invoke-RestMethod -Uri $DvfDatasetApiUrl -Method Get -TimeoutSec 45
        $dvfReleases = @(Get-DvfReleases -Dataset $dvfDataset)
    }
    catch {
        $message = "catalogue DVF indisponible ou incompatible : $($_.Exception.Message)"
        $propertyErrors.Add($message)
        Write-AnnualLog "AVERTISSEMENT : $message"
    }
    try {
        $anilCatalog = Invoke-RestMethod -Uri $AnilCatalogApiUrl -Method Get -TimeoutSec 45
        $anilRelease = Get-LatestAnilRentRelease -Catalog $anilCatalog
    }
    catch {
        $message = "catalogue ANIL indisponible ou incompatible : $($_.Exception.Message)"
        $propertyErrors.Add($message)
        Write-AnnualLog "AVERTISSEMENT : $message"
    }

    $imported = Get-ImportedSourceState
    $importedDvfManifestByYear = @{}
    if ($null -ne $imported.dvfManifestByYear) {
        foreach ($property in $imported.dvfManifestByYear.PSObject.Properties) {
            $importedDvfManifestByYear[[string]$property.Name] = [string]$property.Value
        }
    }
    Write-AnnualLog ("Base immobilière : DVF=[{0}], ANIL={1}, métriques manquantes=[{2}]." -f `
        (($importedDvfManifestByYear.Keys | Sort-Object) -join ', '),
        $imported.rentYear,
        ((ConvertTo-AnnualYearArray -Value $imported.propertyMetricMissingYears) -join ', '))
    if ($importedDvfManifestByYear.ContainsKey("2025")) {
        Write-AnnualLog "Révision DVF locale 2025 : $($importedDvfManifestByYear['2025'])."
    }
    if ($imported.rentYear -gt 0) {
        Write-AnnualLog "Révision ANIL locale $($imported.rentYear) : $($imported.rentLastModified)."
    }
    $latestDvfRelease = $dvfReleases | Sort-Object Year -Descending | Select-Object -First 1
    if ($null -ne $latestDvfRelease) {
        Write-AnnualLog "Révision DVF catalogue $($latestDvfRelease.Year) : $($latestDvfRelease.ManifestHash)."
    }
    if ($null -ne $anilRelease) {
        Write-AnnualLog ("Correspondance ANIL locale/catalogue : URL={0}, révision={1}." -f `
            ($imported.rentApartmentUrl -eq $anilRelease.ApartmentUrl),
            ($imported.rentLastModified -eq $anilRelease.LastModified))
    }
    $plan = New-AnnualImportPlan `
        -SsmiRelease $ssmiRelease `
        -PopulationRelease $populationRelease `
        -ImportedCrimeYear $imported.crimeYear `
        -ImportedCrimeUrl $imported.crimeUrl `
        -ImportedCrimeLastModified $imported.crimeLastModified `
        -ImportedPopulationYear $imported.populationYear `
        -ImportedPopulationUrl $imported.populationUrl `
        -ImportedPopulationLastModified $imported.populationLastModified `
        -MetricsSnapshotAt $imported.metricsSnapshotAt `
        -LatestMetricsImportAt $imported.latestMetricsImportAt `
        -DvfReleases $dvfReleases `
        -ImportedDvfManifestByYear $importedDvfManifestByYear `
        -AnilRentRelease $anilRelease `
        -ImportedRentYear $imported.rentYear `
        -ImportedRentApartmentUrl $imported.rentApartmentUrl `
        -ImportedRentLastModified $imported.rentLastModified `
        -ImportedRentCatalogManifestHash $imported.rentCatalogManifestHash `
        -PropertyMetricMissingYears (ConvertTo-AnnualYearArray -Value $imported.propertyMetricMissingYears)

    Write-AnnualLog "SSMSI disponible : année $($ssmiRelease.Year), géographie $($ssmiRelease.GeographyYear), modifiée $($ssmiRelease.LastModified)."
    Write-AnnualLog "Insee disponible : population de référence $($populationRelease.Year), modifiée $($populationRelease.LastModified)."
    Write-AnnualLog "Base locale : SSMSI $($imported.crimeYear), Insee $($imported.populationYear)."
    if ($dvfReleases.Count -gt 0) {
        Write-AnnualLog "DVF disponible : millésimes $((@($dvfReleases.Year) -join ', ')), révision $($dvfReleases[-1].LastModified)."
    }
    if ($null -ne $anilRelease) {
        Write-AnnualLog "ANIL disponible : millésime $($anilRelease.Year), révision $($anilRelease.LastModified)."
    }

    if (-not $plan.HasUpdates -and $propertyErrors.Count -eq 0) {
        Write-AnnualLog "Aucune nouvelle livraison et l'instantané statistique est à jour. Aucun import lancé."
        return
    }

    Write-AnnualLog ("Plan : population={0}, SSMSI={1}, contours={2}, métriques sécurité={3}, DVF=[{4}], ANIL={5}, métriques immobilières=[{6}]." -f `
        $plan.ImportPopulation,
        $plan.ImportCrime,
        $plan.RefreshBoundaries,
        ($plan.RefreshMetrics -or $plan.ImportPopulation -or $plan.ImportCrime),
        ($plan.ImportDvfYears -join ', '),
        $plan.ImportRentYear,
        ($plan.RefreshPropertyMarketYears -join ', '))
    if ($PlanOnly) {
        Write-AnnualLog "Mode aperçu : aucune donnée ni métrique n'a été modifiée."
        if ($propertyErrors.Count -gt 0) {
            throw "Le plan immobilier est incomplet : $($propertyErrors -join ' | ')"
        }
        return
    }

    $commonArguments = @{
        ContainerName = $ContainerName
        DatabaseName = $DatabaseName
        DatabaseUser = $DatabaseUser
        DatabasePassword = $DatabasePassword
    }

    if ($plan.RefreshBoundaries) {
        $administrativeArguments = $commonArguments.Clone()
        $administrativeArguments.SourceYear = $ssmiRelease.GeographyYear
        $administrativeArguments.DeferMetricsRefresh = $true
        Invoke-ImportStep `
            -Name "référentiel des régions, départements et communes" `
            -Path (Join-Path $PSScriptRoot "import_administrative_areas.ps1") `
            -Arguments $administrativeArguments

        $coordinateArguments = $commonArguments.Clone()
        $coordinateArguments.SourceYear = $ssmiRelease.GeographyYear
        Invoke-ImportStep `
            -Name "coordonnées des communes" `
            -Path (Join-Path $PSScriptRoot "import_city_coordinates.ps1") `
            -Arguments $coordinateArguments

        $boundaryArguments = $commonArguments.Clone()
        $boundaryArguments.SourceYear = $ssmiRelease.GeographyYear
        Invoke-ImportStep `
            -Name "contours polygonaux des communes" `
            -Path (Join-Path $PSScriptRoot "import_city_boundaries.ps1") `
            -Arguments $boundaryArguments
    }

    if ($plan.ImportPopulation) {
        $populationArguments = $commonArguments.Clone()
        $populationArguments.PopulationFileUrl = $populationRelease.Url
        $populationArguments.PopulationYear = $populationRelease.Year
        $populationArguments.SourceLastModified = $populationRelease.LastModified
        $populationArguments.DeferMetricsRefresh = $true
        Invoke-ImportStep `
            -Name "populations de référence Insee $($populationRelease.Year)" `
            -Path (Join-Path $PSScriptRoot "import_population_insee.ps1") `
            -Arguments $populationArguments
    }

    if ($plan.ImportCrime) {
        $crimeArguments = $commonArguments.Clone()
        $crimeArguments.CrimeFileUrl = $ssmiRelease.Url
        $crimeArguments.Year = $ssmiRelease.Year
        $crimeArguments.GeographyYear = $ssmiRelease.GeographyYear
        $crimeArguments.SourceLastModified = $ssmiRelease.LastModified
        $crimeArguments.DeferMetricsRefresh = $true
        Invoke-ImportStep `
            -Name "statistiques SSMSI $($ssmiRelease.Year)" `
            -Path (Join-Path $PSScriptRoot "import_crime_data_ssmsi.ps1") `
            -Arguments $crimeArguments
    }

    if ($plan.ImportCrime -or $plan.ImportPopulation -or $plan.RefreshMetrics) {
        Invoke-ImportStep `
            -Name "reconstruction atomique des métriques de recherche" `
            -Path (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
            -Arguments $commonArguments
    }

    $departmentCodes = @()
    if ($plan.ImportDvfYears.Count -gt 0) {
        $departmentCodes = @(Get-DepartmentCodes)
    }
    $propertyImportedYears = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($year in $plan.ImportDvfYears) {
        $release = $dvfReleases | Where-Object Year -eq $year | Select-Object -First 1
        try {
            if ($null -eq $release) { throw "la publication DVF $year n'est plus résolue dans le catalogue" }
            $sourceUrls = @(Get-DvfDepartmentUrls -Release $release -DepartmentCodes $departmentCodes)
            if ($sourceUrls.Count -eq 0) { throw "aucun département couvert n'est disponible pour DVF $year" }
            $dvfArguments = $commonArguments.Clone()
            $dvfArguments.Year = $year
            $dvfArguments.SourceUrls = $sourceUrls
            $dvfArguments.SourceLastModified = $release.LastModified
            $dvfArguments.SourceManifestHash = $release.ManifestHash
            Invoke-ImportStep `
                -Name "prix d'achat DVF $year" `
                -Path (Join-Path $PSScriptRoot "import_property_sales_dvf.ps1") `
                -Arguments $dvfArguments
            [void]$propertyImportedYears.Add([int]$year)
        }
        catch {
            $message = "import DVF $year échoué : $($_.Exception.Message)"
            $propertyErrors.Add($message)
            Write-AnnualLog "ÉCHEC IMMOBILIER : $message"
        }
    }

    if ($plan.ImportRentYear -gt 0) {
        try {
            if ($null -eq $anilRelease -or $anilRelease.Year -ne $plan.ImportRentYear) {
                throw "la publication ANIL $($plan.ImportRentYear) n'est plus résolue dans le catalogue"
            }
            $rentArguments = $commonArguments.Clone()
            $rentArguments.Year = $anilRelease.Year
            $rentArguments.ApartmentFileUrl = $anilRelease.ApartmentUrl
            $rentArguments.HouseFileUrl = $anilRelease.HouseUrl
            $rentArguments.ApartmentResourceId = $anilRelease.ApartmentResourceId
            $rentArguments.HouseResourceId = $anilRelease.HouseResourceId
            $rentArguments.SourceLastModified = $anilRelease.LastModified
            $rentArguments.SourceCatalogManifestHash = $anilRelease.ManifestHash
            Invoke-ImportStep `
                -Name "loyers d'annonce ANIL $($anilRelease.Year)" `
                -Path (Join-Path $PSScriptRoot "import_property_rents_anil.ps1") `
                -Arguments $rentArguments
            [void]$propertyImportedYears.Add([int]$anilRelease.Year)
        }
        catch {
            $message = "import ANIL $($plan.ImportRentYear) échoué : $($_.Exception.Message)"
            $propertyErrors.Add($message)
            Write-AnnualLog "ÉCHEC IMMOBILIER : $message"
        }
    }

    foreach ($year in $plan.RefreshPropertyMarketYears) {
        if ($propertyImportedYears.Contains([int]$year)) { continue }
        try {
            $refreshArguments = $commonArguments.Clone()
            $refreshArguments.Year = $year
            Invoke-ImportStep `
                -Name "reconstruction des métriques immobilières $year" `
                -Path (Join-Path $PSScriptRoot "refresh_property_market_metrics.ps1") `
                -Arguments $refreshArguments
        }
        catch {
            $message = "métriques immobilières $year échouées : $($_.Exception.Message)"
            $propertyErrors.Add($message)
            Write-AnnualLog "ÉCHEC IMMOBILIER : $message"
        }
    }

    if ($propertyErrors.Count -gt 0) {
        throw "Une ou plusieurs mises à jour immobilières n'ont pas abouti : $($propertyErrors -join ' | ')"
    }
    Write-AnnualLog "Mise à jour officielle terminée."
}
catch {
    Write-AnnualLog "ÉCHEC : $($_.Exception.Message)"
    throw "Annual official-data update failed. See '$logPath'. $($_.Exception.Message)"
}
