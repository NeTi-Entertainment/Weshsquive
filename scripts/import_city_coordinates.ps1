param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$CitiesUrl = "https://geo.api.gouv.fr/communes?fields=nom,code,centre&format=json",
    [string]$Source = "geo.api.gouv.fr-centre",
    [int]$SourceYear
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

function Read-JsonArray {
    param([Parameter(Mandatory = $true)][string]$Location)

    if (Test-Path -LiteralPath $Location) {
        $data = Get-Content -LiteralPath $Location -Raw | ConvertFrom-Json
    }
    else {
        $data = Invoke-RestMethod -Uri $Location -Method Get
    }

    if ($null -eq $data) {
        throw "No JSON data returned from $Location"
    }

    if ($data -isnot [System.Array]) {
        throw "Expected a JSON array from $Location"
    }

    return $data | ConvertTo-Json -Compress -Depth 20
}

function Invoke-GeneratedSql {
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
            psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -f "/tmp/$Name.sql" `
            | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to execute generated SQL batch $Name"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

$citiesJson = Read-JsonArray -Location $CitiesUrl
$sourceLiteral = ConvertTo-SqlLiteral -Value $Source
$sourceUrlLiteral = ConvertTo-SqlLiteral -Value $CitiesUrl
$sourceYearLiteral = if ($PSBoundParameters.ContainsKey("SourceYear")) { $SourceYear.ToString() } else { "null" }
$metadataLiteral = ConvertTo-SqlLiteral -Value (@{
    citiesUrl = $CitiesUrl
    geometry = "centre"
    coordinateReferenceSystem = "WGS84"
} | ConvertTo-Json -Compress)
$coordinateRowsPayload = "`$coordinate_rows`$`n$citiesJson`n`$coordinate_rows`$::jsonb"
$coverageGuard = @"
do `$coordinate_guard`$
declare
    existing_city_count integer;
    incoming_city_count integer;
begin
    select count(*) into existing_city_count from cities;
    select count(distinct source_rows.code) into incoming_city_count
    from jsonb_to_recordset($coordinateRowsPayload)
        as source_rows(code text, nom text, centre jsonb)
    join cities on cities.insee_code = source_rows.code
    where source_rows.code ~ '^[0-9A-Z]{5}$'
      and jsonb_typeof(source_rows.centre) = 'object'
      and jsonb_typeof(source_rows.centre -> 'coordinates') = 'array'
      and jsonb_array_length(source_rows.centre -> 'coordinates') >= 2
      and jsonb_typeof(source_rows.centre -> 'coordinates' -> 0) = 'number'
      and jsonb_typeof(source_rows.centre -> 'coordinates' -> 1) = 'number'
      and (source_rows.centre #>> '{coordinates,1}')::numeric between -90 and 90
      and (source_rows.centre #>> '{coordinates,0}')::numeric between -180 and 180;

    if incoming_city_count = 0 then
        raise exception 'Coordinate source contains no valid known commune centers';
    end if;
    if existing_city_count >= 1000 and incoming_city_count < ceil(existing_city_count * 0.90) then
        raise exception 'Coordinate source is incomplete: % valid known centers for % already known communes', incoming_city_count, existing_city_count;
    end if;
end
`$coordinate_guard`$;
"@

$sql = @"
\set ON_ERROR_STOP on

begin;

$coverageGuard

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
);

with payload(data) as (
    values (`$json`$
$citiesJson
`$json`$::jsonb)
),
rows as (
    select *
    from jsonb_to_recordset((select data from payload))
        as r(code text, nom text, centre jsonb)
),
coordinates as (
    select
        code,
        (centre #>> '{coordinates,1}')::numeric as latitude,
        (centre #>> '{coordinates,0}')::numeric as longitude
    from rows
    where code is not null
      and jsonb_typeof(centre) = 'object'
      and jsonb_typeof(centre -> 'coordinates') = 'array'
      and jsonb_array_length(centre -> 'coordinates') >= 2
),
valid_coordinates as (
    select code, latitude, longitude
    from coordinates
    where latitude between -90 and 90
      and longitude between -180 and 180
)
update cities
set
    latitude = valid_coordinates.latitude,
    longitude = valid_coordinates.longitude,
    updated_at = now()
from valid_coordinates
where cities.insee_code = valid_coordinates.code
  and (cities.latitude, cities.longitude)
      is distinct from (valid_coordinates.latitude, valid_coordinates.longitude);

commit;
"@

Invoke-GeneratedSql -Sql $sql -Name "import-city-coordinates"

Write-Host "City coordinates imported from $Source."
