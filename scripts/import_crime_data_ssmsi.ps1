param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$CrimeFileUrl = "https://static.data.gouv.fr/resources/bases-statistiques-communale-departementale-et-regionale-de-la-delinquance-enregistree-par-la-police-et-la-gendarmerie-nationales/20260709-115942/donnee-data.gouv-2025-geographie2026-produit-le2026-06-25.csv.gz",
    [int]$Year,
    [int]$GeographyYear,
    [string]$Source = "ssmsi-base-communale",
    [string]$SourceLastModified = "",
    [switch]$DeferMetricsRefresh
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
    $DatabaseName = "app_criminalite"
}

if ([string]::IsNullOrWhiteSpace($DatabaseUser)) {
    $DatabaseUser = "app"
}

if ([string]::IsNullOrWhiteSpace($DatabasePassword)) {
    $DatabasePassword = "app_dev_password"
}

function ConvertTo-SqlLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "null"
    }

    return "'" + $Value.Replace("'", "''") + "'"
}

function Resolve-CrimeCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Location,
        [Parameter(Mandatory = $true)]
        [string]$WorkDir
    )

    $inputPath = $Location
    if (-not (Test-Path -LiteralPath $Location -PathType Leaf)) {
        $inputPath = Join-Path $WorkDir "ssmsi-source"
        if ($Location.ToLowerInvariant().EndsWith(".gz")) {
            $inputPath = "$inputPath.gz"
        }
        Invoke-WebRequest -Uri $Location -OutFile $inputPath
    }

    $extension = [System.IO.Path]::GetExtension($inputPath).ToLowerInvariant()
    $isGzip = $extension -eq ".gz"
    if (-not $isGzip) {
        $bytes = [System.IO.File]::ReadAllBytes($inputPath)
        $isGzip = $bytes.Length -ge 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b
    }

    if ($isGzip) {
        $csvPath = Join-Path $WorkDir "ssmsi.csv"
        $sourceStream = [System.IO.File]::OpenRead($inputPath)
        try {
            $gzipStream = [System.IO.Compression.GZipStream]::new(
                $sourceStream,
                [System.IO.Compression.CompressionMode]::Decompress
            )
            try {
                $targetStream = [System.IO.File]::Create($csvPath)
                try {
                    $gzipStream.CopyTo($targetStream)
                }
                finally {
                    $targetStream.Dispose()
                }
            }
            finally {
                $gzipStream.Dispose()
            }
        }
        finally {
            $sourceStream.Dispose()
        }

        return $csvPath
    }

    return (Resolve-Path -LiteralPath $inputPath).Path
}

function ConvertTo-LinuxCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsvPath,
        [Parameter(Mandatory = $true)]
        [string]$WorkDir
    )

    $normalizedPath = Join-Path $WorkDir "ssmsi-normalized.csv"

    $reader = [System.IO.StreamReader]::new($CsvPath, [System.Text.Encoding]::UTF8, $true)
    try {
        $writer = [System.IO.StreamWriter]::new($normalizedPath, $false, [System.Text.UTF8Encoding]::new($false))
        try {
            while (-not $reader.EndOfStream) {
                $writer.WriteLine($reader.ReadLine())
            }
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $reader.Dispose()
    }

    return $normalizedPath
}

function Invoke-SqlFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-$PID.sql"

    try {
        Set-Content -LiteralPath $tempPath -Value $Sql -Encoding utf8
        docker cp $tempPath "${ContainerName}:/tmp/$Name.sql"
        if ($LASTEXITCODE -ne 0) {
            throw "Could not copy generated SQL batch $Name into $ContainerName"
        }

        docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
            psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -f "/tmp/$Name.sql"

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to execute SQL batch $Name"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-ssmsi-$PID"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    $csvPath = Resolve-CrimeCsv -Location $CrimeFileUrl -WorkDir $workDir
    if ([string]::IsNullOrWhiteSpace($csvPath) -or -not (Test-Path -LiteralPath $csvPath)) {
        throw "SSMSI CSV not found from $CrimeFileUrl"
    }

    $firstRow = Import-Csv -LiteralPath $csvPath -Delimiter ';' | Select-Object -First 1
    if ($null -eq $firstRow) {
        throw "SSMSI CSV contains no data rows: $CrimeFileUrl"
    }

    $sourceColumns = @($firstRow.PSObject.Properties.Name)
    $expectedSourceTail = @(
        "annee", "indicateur", "unite_de_compte", "nombre", "taux_pour_mille",
        "est_diffuse", "insee_pop", "insee_pop_millesime", "insee_log",
        "insee_log_millesime", "complement_info_nombre", "complement_info_taux"
    )
    $headerMatches = $sourceColumns.Count -eq ($expectedSourceTail.Count + 1) `
        -and $sourceColumns[0] -match '^CODGEO_20\d{2}$'
    if ($headerMatches) {
        for ($index = 0; $index -lt $expectedSourceTail.Count; $index++) {
            if ($sourceColumns[$index + 1] -ne $expectedSourceTail[$index]) {
                $headerMatches = $false
                break
            }
        }
    }
    if (-not $headerMatches) {
        throw "SSMSI CSV columns are not compatible with the importer. No data was imported."
    }
    if ($PSBoundParameters.ContainsKey("GeographyYear") -and $sourceColumns[0] -ne "CODGEO_$GeographyYear") {
        throw "SSMSI geography column '$($sourceColumns[0])' does not match catalog geography year $GeographyYear. No data was imported."
    }

    $normalizedCsvPath = ConvertTo-LinuxCsv -CsvPath $csvPath -WorkDir $workDir
    docker cp $normalizedCsvPath "${ContainerName}:/tmp/ssmsi-crime-data.csv"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy the normalized SSMSI CSV into '$ContainerName'."
    }

    $sourceLiteral = ConvertTo-SqlLiteral -Value $Source
    $sourceUrlLiteral = ConvertTo-SqlLiteral -Value $CrimeFileUrl
    $sourceYearLiteral = if ($PSBoundParameters.ContainsKey("Year")) { $Year.ToString() } else { "null" }
    $yearFilter = if ($PSBoundParameters.ContainsKey("Year")) { "where raw.annee::integer = $Year" } else { "" }
    $yearValidation = if ($PSBoundParameters.ContainsKey("Year")) {
@"
do `$annual_guard`$
declare
    expected_city_count integer;
    loaded_city_count integer;
    category_count integer;
begin
    select count(*) into expected_city_count from cities;
    select count(distinct cities.insee_code), count(distinct raw.indicateur)
    into loaded_city_count, category_count
    from ssmsi_raw raw
    join cities on cities.insee_code = raw.codgeo_2026
    where raw.annee ~ '^[0-9]{4}$'
        and raw.annee::integer = $Year
        and raw.indicateur is not null;

    if loaded_city_count = 0 then
        raise exception 'SSMSI source contains no known communes for requested year $Year';
    end if;
    if expected_city_count >= 1000 and (
        loaded_city_count < ceil(expected_city_count * 0.90)
        or category_count < 10
    ) then
        raise exception 'SSMSI source appears incomplete for year ${Year}: % communes and % categories', loaded_city_count, category_count;
    end if;

    if not exists (
        select 1
        from ssmsi_raw
        where annee ~ '^[0-9]{4}$'
            and annee::integer = $Year
    ) then
        raise exception 'SSMSI source contains no rows for requested year $Year';
    end if;
end
`$annual_guard`$;
"@
    }
    else {
        ""
    }
    $yearReplacement = if ($PSBoundParameters.ContainsKey("Year")) {
        "delete from crime_stats where source = $sourceLiteral and year = $Year;"
    }
    else {
        ""
    }
    $metadataLiteral = ConvertTo-SqlLiteral -Value (@{
        crimeFileUrl = $CrimeFileUrl
        filteredYear = if ($PSBoundParameters.ContainsKey("Year")) { $Year } else { $null }
        catalogLastModified = $SourceLastModified
        sourceColumns = $sourceColumns
        rateDenominatorReferenceVersion = "ssmsi-rate-denominator-2026-v1"
    } | ConvertTo-Json -Compress)

    $sql = @"
\set ON_ERROR_STOP on

begin;

create temp table ssmsi_raw (
    codgeo_2026 text,
    annee text,
    indicateur text,
    unite_de_compte text,
    nombre text,
    taux_pour_mille text,
    est_diffuse text,
    insee_pop text,
    insee_pop_millesime text,
    insee_log text,
    insee_log_millesime text,
    complement_info_nombre text,
    complement_info_taux text
) on commit drop;

\copy ssmsi_raw from '/tmp/ssmsi-crime-data.csv' with (format csv, header true, delimiter ';', quote '"', null 'NA')

$yearValidation

$yearReplacement

with import_batch as (
    insert into import_batches (
        source_system,
        source_url,
        source_year,
        status,
        metadata,
        completed_at
    )
    values (
        $sourceLiteral,
        $sourceUrlLiteral,
        $sourceYearLiteral,
        'completed',
        $metadataLiteral::jsonb,
        now()
    )
    returning id
),
source_rows as (
    select
        raw.codgeo_2026 as city_insee_code,
        raw.annee::integer as year,
        raw.indicateur as category_label,
        'ssmsi-' || md5(raw.indicateur) as category_code,
        nullif(raw.unite_de_compte, 'NA') as count_unit,
        case raw.indicateur
            when 'Cambriolages de logement' then 'housing'
            when 'Destructions et dégradations volontaires' then 'population'
            when 'Escroqueries et fraudes aux moyens de paiement' then 'population'
            when 'Trafic de stupéfiants' then 'population'
            when 'Usage de stupéfiants' then 'population'
            when 'Usage de stupéfiants (AFD)' then 'population'
            when 'Violences physiques hors cadre familial' then 'population'
            when 'Violences physiques intrafamiliales' then 'population'
            when 'Violences sexuelles' then 'population'
            when 'Vols avec armes' then 'population'
            when 'Vols d''accessoires sur véhicules' then 'population'
            when 'Vols dans les véhicules' then 'population'
            when 'Vols de véhicule' then 'population'
            when 'Vols sans violence contre des personnes' then 'population'
            when 'Vols violents sans arme' then 'population'
            else 'unknown'
        end as rate_denominator_reference,
        case
            when raw.est_diffuse = 'diff' and raw.nombre is not null
                then raw.nombre::integer
            else null
        end as incident_count,
        case
            when raw.est_diffuse = 'diff' and raw.taux_pour_mille is not null
                then replace(raw.taux_pour_mille, ',', '.')::numeric
            else null
        end as rate_per_1000,
        case
            when raw.est_diffuse = 'diff' then 'published'::publication_status
            when raw.est_diffuse = 'ndiff' then 'masked'::publication_status
            else 'unknown'::publication_status
        end as publication_status,
        nullif(raw.insee_pop, 'NA')::bigint as insee_pop,
        nullif(raw.insee_pop_millesime, 'NA')::smallint as insee_pop_millesime,
        nullif(raw.insee_log, 'NA')::bigint as insee_log,
        nullif(raw.insee_log_millesime, 'NA')::smallint as insee_log_millesime,
        replace(nullif(raw.complement_info_nombre, 'NA'), ',', '.')::numeric as complement_info_nombre,
        replace(nullif(raw.complement_info_taux, 'NA'), ',', '.')::numeric as complement_info_taux
    from ssmsi_raw raw
    $yearFilter
),
known_city_rows as (
    select source_rows.*
    from source_rows
    join cities on cities.insee_code = source_rows.city_insee_code
    where source_rows.year between 2000 and 2100
        and source_rows.category_label is not null
),
classified_rows as (
    select
        known_city_rows.*,
        case
            when rate_denominator_reference = 'unknown' then 'unknown'
            when count_unit is null then 'unknown'
            when publication_status = 'published'
                and rate_per_1000 is not null
                and incident_count is not null
                and rate_denominator_reference = 'population'
                and (
                    insee_pop is null or insee_pop = 0
                    or abs(rate_per_1000 - incident_count::numeric * 1000 / insee_pop) > 0.0051
                ) then 'unknown'
            when publication_status = 'published'
                and rate_per_1000 is not null
                and incident_count is not null
                and rate_denominator_reference = 'housing'
                and (
                    insee_log is null or insee_log = 0
                    or abs(rate_per_1000 - incident_count::numeric * 1000 / insee_log) > 0.0051
                ) then 'unknown'
            else rate_denominator_reference
        end as rate_denominator,
        publication_status = 'published'
            and rate_per_1000 is not null
            and incident_count is not null
            and rate_denominator_reference <> 'unknown'
            and count_unit is not null
            and case rate_denominator_reference
                when 'population' then insee_pop is null or insee_pop = 0
                    or abs(rate_per_1000 - incident_count::numeric * 1000 / insee_pop) > 0.0051
                when 'housing' then insee_log is null or insee_log = 0
                    or abs(rate_per_1000 - incident_count::numeric * 1000 / insee_log) > 0.0051
                else false
            end as rate_denominator_mismatch
    from known_city_rows
),
inserted_categories as (
    insert into crime_categories (
        code,
        label,
        description,
        rate_denominator_reference,
        source,
        updated_at
    )
    select distinct
        category_code,
        category_label,
        'Unite de compte SSMSI conservee par observation',
        rate_denominator_reference,
        $sourceLiteral,
        now()
    from classified_rows
    on conflict (code) do update
    set
        label = excluded.label,
        description = excluded.description,
        rate_denominator_reference = excluded.rate_denominator_reference,
        source = excluded.source,
        updated_at = now()
    returning id, code
),
imported_stats as (
insert into crime_stats (
    city_insee_code,
    year,
    category_id,
    incident_count,
    rate_per_1000,
    publication_status,
    count_unit,
    insee_pop,
    insee_pop_millesime,
    insee_log,
    insee_log_millesime,
    complement_info_nombre,
    complement_info_taux,
    rate_denominator,
    source,
    import_batch_id,
    imported_at
)
select
    rows.city_insee_code,
    rows.year,
    categories.id,
    rows.incident_count,
    rows.rate_per_1000,
    rows.publication_status,
    rows.count_unit,
    rows.insee_pop,
    rows.insee_pop_millesime,
    rows.insee_log,
    rows.insee_log_millesime,
    rows.complement_info_nombre,
    rows.complement_info_taux,
    rows.rate_denominator,
    $sourceLiteral,
    (select id from import_batch),
    now()
from classified_rows rows
join inserted_categories categories on categories.code = rows.category_code
on conflict (city_insee_code, year, category_id, source) do update
set
    incident_count = excluded.incident_count,
    rate_per_1000 = excluded.rate_per_1000,
    publication_status = excluded.publication_status,
    count_unit = excluded.count_unit,
    insee_pop = excluded.insee_pop,
    insee_pop_millesime = excluded.insee_pop_millesime,
    insee_log = excluded.insee_log,
    insee_log_millesime = excluded.insee_log_millesime,
    complement_info_nombre = excluded.complement_info_nombre,
    complement_info_taux = excluded.complement_info_taux,
    rate_denominator = excluded.rate_denominator,
    import_batch_id = excluded.import_batch_id,
    imported_at = now()
returning id
)

select coalesce(max(total_count), 0)::integer as rate_denominator_mismatch_count,
    coalesce(string_agg(example, E'\n' order by example), 'aucun') as examples
from (
    select city_insee_code || ' ' || year::text || ' ' || category_label as example,
        count(*) over () as total_count
    from classified_rows
    where rate_denominator_mismatch
    order by city_insee_code, year, category_label
    limit 10
) mismatches;

commit;
"@

    Invoke-SqlFile -Sql $sql -Name "import-crime-data-ssmsi"

    if ($DeferMetricsRefresh) {
        Write-Host "SSMSI import committed; derived search metric refresh was deferred."
    }
    else {
        try {
            & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
                -ContainerName $ContainerName `
                -DatabaseName $DatabaseName `
                -DatabaseUser $DatabaseUser `
                -DatabasePassword $DatabasePassword
        }
        catch {
            throw "SSMSI data was committed, but refreshing derived search metrics failed. The previous snapshot remains active. Retry with scripts/refresh_search_metrics.ps1. Details: $($_.Exception.Message)"
        }
    }

    if ($PSBoundParameters.ContainsKey("Year")) {
        Write-Host "SSMSI crime data imported for $Year from $Source."
    }
    else {
        Write-Host "SSMSI crime data imported from $Source."
    }
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
}
