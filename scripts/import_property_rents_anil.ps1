param(
    [Parameter(Mandatory = $true)][ValidateRange(2000, 2100)][int]$Year,
    [Parameter(Mandatory = $true)][string]$ApartmentFileUrl,
    [Parameter(Mandatory = $true)][string]$HouseFileUrl,
    [string]$ApartmentResourceId = "",
    [string]$HouseResourceId = "",
    [string]$SourceLastModified = "",
    [string]$SourceCatalogManifestHash = "",
    [switch]$EnforceNationalCoverage,
    [ValidateRange(1, 30000)][int]$NationalMinimumRowsPerType = 30000,
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$Source = "anil-rent-map"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) { $DatabaseName = "app_criminalite" }
if ([string]::IsNullOrWhiteSpace($DatabaseUser)) { $DatabaseUser = "app" }
if ([string]::IsNullOrWhiteSpace($DatabasePassword)) { $DatabasePassword = "app_dev_password" }

$apartmentIsLocal = Test-Path -LiteralPath $ApartmentFileUrl -PathType Leaf
$houseIsLocal = Test-Path -LiteralPath $HouseFileUrl -PathType Leaf
if ($apartmentIsLocal -ne $houseIsLocal) {
    throw "ANIL apartment and house sources must both be local or both be official remote resources."
}
if (-not $apartmentIsLocal) {
    foreach ($location in @($ApartmentFileUrl, $HouseFileUrl)) {
        if ($location -notmatch "/resources/carte-des-loyers-.+-commune-en-$Year/") {
            throw "ANIL resource year does not match requested year $Year."
        }
    }
    if ($NationalMinimumRowsPerType -ne 30000) {
        throw "The national ANIL minimum cannot be lowered for remote resources."
    }
}

function ConvertTo-SqlLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "null" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Resolve-AnilCsv {
    param([string]$Location, [string]$Destination)
    if (Test-Path -LiteralPath $Location -PathType Leaf) {
        [System.IO.File]::Copy((Resolve-Path -LiteralPath $Location).Path, $Destination, $true)
        return $Destination
    }

    $uri = [uri]$Location
    $trustedHost = $uri.Host -in @("static.data.gouv.fr", "www.data.gouv.fr")
    $trustedPath = $uri.Host -eq "static.data.gouv.fr" -or $uri.AbsolutePath.StartsWith("/api/1/datasets/r/")
    if ($uri.Scheme -ne "https" -or -not $trustedHost -or -not $trustedPath) {
        throw "ANIL downloads must use an official data.gouv.fr resource URL."
    }
    Invoke-WebRequest -Uri $Location -OutFile $Destination -TimeoutSec 300
    return $Destination
}

function Read-SemicolonHeader {
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($Path, [System.Text.Encoding]::GetEncoding(1252), $true)
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(";")
        $parser.HasFieldsEnclosedInQuotes = $true
        return @($parser.ReadFields() | ForEach-Object { $_.Trim().TrimStart([char]0xfeff) })
    }
    finally { $parser.Dispose() }
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-anil-$PID"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    $apartmentPath = Resolve-AnilCsv -Location $ApartmentFileUrl -Destination (Join-Path $workDir "apartments.csv")
    $housePath = Resolve-AnilCsv -Location $HouseFileUrl -Destination (Join-Path $workDir "houses.csv")
    $expectedHeader = @(
        "id_zone", "INSEE_C", "LIBGEO", "EPCI", "DEP", "REG", "loypredm2",
        "lwr.IPm2", "upr.IPm2", "TYPPRED", "nbobs_com", "nbobs_mail", "R2_adj"
    )
    foreach ($path in @($apartmentPath, $housePath)) {
        if ((Get-Item -LiteralPath $path).Length -eq 0) { throw "ANIL source '$path' is empty." }
        $header = @(Read-SemicolonHeader -Path $path)
        if (($header -join "`n") -ne ($expectedHeader -join "`n")) {
            throw "ANIL CSV columns are not compatible with the importer. No data was imported."
        }
    }

    $apartmentHash = (Get-FileHash -LiteralPath $apartmentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $houseHash = (Get-FileHash -LiteralPath $housePath -Algorithm SHA256).Hash.ToLowerInvariant()
    docker cp $apartmentPath "${ContainerName}:/tmp/anil-apartments-$Year.csv"
    if ($LASTEXITCODE -ne 0) { throw "Could not copy the ANIL apartment file into '$ContainerName'." }
    docker cp $housePath "${ContainerName}:/tmp/anil-houses-$Year.csv"
    if ($LASTEXITCODE -ne 0) { throw "Could not copy the ANIL house file into '$ContainerName'." }

    $metadata = @{
        apartmentFileUrl = $ApartmentFileUrl
        houseFileUrl = $HouseFileUrl
        apartmentResourceId = $ApartmentResourceId
        houseResourceId = $HouseResourceId
        sourceLastModified = $SourceLastModified
        catalogManifestHash = $SourceCatalogManifestHash
        apartmentSha256 = $apartmentHash
        houseSha256 = $houseHash
        sourceColumns = $expectedHeader
    } | ConvertTo-Json -Compress -Depth 4
    $sourceLiteral = ConvertTo-SqlLiteral $Source
    $metadataLiteral = ConvertTo-SqlLiteral $metadata
    $lastModifiedLiteral = ConvertTo-SqlLiteral $SourceLastModified
    $catalogManifestHashLiteral = ConvertTo-SqlLiteral $SourceCatalogManifestHash
    $productionCoverageGuard = if (-not $apartmentIsLocal -or $EnforceNationalCoverage) {
@"
    if (select count(*) from anil_apartment_raw) < $NationalMinimumRowsPerType
       or (select count(*) from anil_house_raw) < $NationalMinimumRowsPerType then
        raise exception 'ANIL source coverage is incomplete: too few raw rows per property type';
    end if;
    if exists (
        select 1
        from (values ('apartment'), ('house')) expected(property_type)
        where (
            select count(*)
            from anil_normalized normalized
            join cities city on city.insee_code = normalized.city_insee_code
            where normalized.property_type = expected.property_type
        ) < ceil((
            select count(*) * 0.95
            from anil_normalized normalized
            where normalized.property_type = expected.property_type
        ))
    ) then
        raise exception 'ANIL retained commune coverage is below 95 percent';
    end if;
    if exists (
        select 1
        from (values ('apartment'), ('house')) expected(property_type)
        where (
            select count(*)
            from property_rent_observations previous
            where previous.source_system = $sourceLiteral
              and previous.source_year = $Year
              and previous.property_type = expected.property_type
        ) > 0
          and (
            select count(*)
            from anil_normalized normalized
            join cities city on city.insee_code = normalized.city_insee_code
            where normalized.property_type = expected.property_type
          ) < (
            select count(*) * 0.8
            from property_rent_observations previous
            where previous.source_system = $sourceLiteral
              and previous.source_year = $Year
              and previous.property_type = expected.property_type
          )
    ) then
        raise exception 'ANIL retained coverage dropped by more than 20 percent from the active publication';
    end if;
"@
    } else { "" }

    $sql = @"
\set ON_ERROR_STOP on
begin;

create temp table anil_apartment_raw (
    id_zone text, "INSEE_C" text, "LIBGEO" text, "EPCI" text, "DEP" text,
    "REG" text, loypredm2 text, "lwr.IPm2" text, "upr.IPm2" text,
    "TYPPRED" text, nbobs_com text, nbobs_mail text, "R2_adj" text
) on commit drop;
create temp table anil_house_raw (like anil_apartment_raw) on commit drop;

\copy anil_apartment_raw from '/tmp/anil-apartments-$Year.csv' with (format csv, header true, delimiter ';', quote '"', encoding 'WIN1252')
\copy anil_house_raw from '/tmp/anil-houses-$Year.csv' with (format csv, header true, delimiter ';', quote '"', encoding 'WIN1252')

create temp table anil_normalized on commit drop as
select
    property_type,
    nullif(trim("INSEE_C"), '') as city_insee_code,
    case when replace(trim(loypredm2), ',', '.') ~ '^-?[0-9]+(?:\.[0-9]+)?$' then replace(trim(loypredm2), ',', '.')::numeric end as estimated_rent_per_m2,
    case when replace(trim("lwr.IPm2"), ',', '.') ~ '^-?[0-9]+(?:\.[0-9]+)?$' then replace(trim("lwr.IPm2"), ',', '.')::numeric end as lower_bound_per_m2,
    case when replace(trim("upr.IPm2"), ',', '.') ~ '^-?[0-9]+(?:\.[0-9]+)?$' then replace(trim("upr.IPm2"), ',', '.')::numeric end as upper_bound_per_m2,
    nullif(lower(trim("TYPPRED")), '') as prediction_type,
    case when trim(nbobs_com) ~ '^[0-9]+$' then trim(nbobs_com)::integer end as commune_observation_count,
    case when trim(nbobs_mail) ~ '^[0-9]+$' then trim(nbobs_mail)::integer end as grid_observation_count,
    case when replace(trim("R2_adj"), ',', '.') ~ '^-?[0-9]+(?:\.[0-9]+)?$' then replace(trim("R2_adj"), ',', '.')::numeric end as adjusted_r2
from (
    select 'apartment'::text as property_type, * from anil_apartment_raw
    union all
    select 'house'::text as property_type, * from anil_house_raw
) source_rows;

do `$guard`$
begin
    if not exists (select 1 from anil_apartment_raw) or not exists (select 1 from anil_house_raw) then
        raise exception 'ANIL source contains no data rows for one property type';
    end if;
    if exists (select 1 from anil_apartment_raw group by "INSEE_C" having count(*) > 1)
       or exists (select 1 from anil_house_raw group by "INSEE_C" having count(*) > 1) then
        raise exception 'ANIL source contains duplicate commune rows';
    end if;
$productionCoverageGuard
end
`$guard`$;

delete from property_rent_observations
where source_system = $sourceLiteral and source_year = $Year;

insert into import_batches(source_system, source_url, source_year, status, metadata, completed_at)
values ($sourceLiteral, $(ConvertTo-SqlLiteral $ApartmentFileUrl), $Year, 'completed', $metadataLiteral::jsonb, now())
returning id as import_batch_id \gset

insert into property_rent_observations(
    source_system, source_year, city_insee_code, property_type,
    estimated_rent_per_m2, lower_bound_per_m2, upper_bound_per_m2,
    prediction_type, commune_observation_count, grid_observation_count,
    adjusted_r2, import_batch_id
)
select
    $sourceLiteral, $Year, normalized.city_insee_code, normalized.property_type,
    normalized.estimated_rent_per_m2, normalized.lower_bound_per_m2,
    normalized.upper_bound_per_m2, normalized.prediction_type,
    normalized.commune_observation_count, normalized.grid_observation_count,
    normalized.adjusted_r2, :import_batch_id
from anil_normalized normalized
join cities city on city.insee_code = normalized.city_insee_code;

update import_batches
set metadata = metadata || jsonb_build_object(
    'rawApartmentCount', (select count(*) from anil_apartment_raw),
    'rawHouseCount', (select count(*) from anil_house_raw),
    'retainedObservationCount', (select count(*) from property_rent_observations where source_system = $sourceLiteral and source_year = $Year),
    'unknownCityCount', (select count(*) from anil_normalized normalized where not exists (select 1 from cities city where city.insee_code = normalized.city_insee_code)),
    'catalogLastModified', $lastModifiedLiteral,
    'catalogManifestHash', $catalogManifestHashLiteral
)
where id = :import_batch_id;

select refresh_property_market_metrics($Year::smallint);
commit;
"@

    $sqlPath = Join-Path $workDir "import-anil.sql"
    [System.IO.File]::WriteAllText($sqlPath, $sql, [System.Text.UTF8Encoding]::new($false))
    docker cp $sqlPath "${ContainerName}:/tmp/import-anil-rents.sql"
    if ($LASTEXITCODE -ne 0) { throw "Could not copy generated ANIL SQL into '$ContainerName'." }

    $psqlOutput = & docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -f "/tmp/import-anil-rents.sql" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ANIL rent import failed; the previous year remains active. $($psqlOutput -join ' ')"
    }
    $psqlOutput | Write-Host
}
finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
