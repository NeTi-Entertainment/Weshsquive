param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$Source = "geo.api.gouv.fr-city-boundaries",
    [string]$SourceUrl,
    [int]$SourceYear
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) { $DatabaseName = "app_criminalite" }
if ([string]::IsNullOrWhiteSpace($DatabaseUser)) { $DatabaseUser = "app" }
if ([string]::IsNullOrWhiteSpace($DatabasePassword)) { $DatabasePassword = "app_dev_password" }
$containerPayloadPath = "/tmp/import-city-boundaries-$PID.jsonl"

function ConvertTo-SqlLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return "null" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Psql {
    param([Parameter(Mandatory = $true)][string]$Sql)

    $output = & docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -q -t -A -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not query PostgreSQL: $($output -join ' ')"
    }
    return $output
}

function Read-FeatureCollection {
    param([Parameter(Mandatory = $true)][string]$Location)

    if (Test-Path -LiteralPath $Location -PathType Leaf) {
        $collection = Get-Content -LiteralPath $Location -Raw | ConvertFrom-Json -Depth 100
    }
    else {
        $collection = Invoke-RestMethod -Uri $Location -Method Get -TimeoutSec 120
    }

    if ($null -eq $collection -or $collection.type -ne "FeatureCollection" -or $null -eq $collection.features) {
        throw "Expected a GeoJSON FeatureCollection from $Location."
    }
    $features = @($collection.features)
    if ($features.Count -eq 0) {
        throw "Boundary source returned no commune contours from $Location."
    }
    return $features
}

function Get-DepartmentCodes {
    $output = Invoke-Psql -Sql "select code from departments order by code;"
    $codes = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($codes.Count -eq 0) { throw "No departments are present in the database." }
    return $codes
}

function Invoke-GeneratedSql {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$PayloadPath
    )

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-$PID.sql"
    try {
        Set-Content -LiteralPath $tempPath -Value $Sql -Encoding utf8
        docker cp $PayloadPath "${ContainerName}:$containerPayloadPath" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not copy boundary staging data into $ContainerName." }
        docker cp $tempPath "${ContainerName}:/tmp/$Name.sql" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not copy generated SQL batch $Name into $ContainerName." }

        $output = & docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
            psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -f "/tmp/$Name.sql" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to import city boundaries: $($output -join ' ')"
        }
    }
    finally {
        & docker exec $ContainerName rm -f $containerPayloadPath "/tmp/$Name.sql" *> $null
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
        if (Test-Path -LiteralPath $PayloadPath) { Remove-Item -LiteralPath $PayloadPath -Force }
    }
}

$sourceUrls = [System.Collections.Generic.List[string]]::new()
$features = [System.Collections.Generic.List[object]]::new()
if (-not [string]::IsNullOrWhiteSpace($SourceUrl)) {
    $sourceUrls.Add($SourceUrl)
    foreach ($feature in (Read-FeatureCollection -Location $SourceUrl)) {
        $features.Add($feature)
    }
}
else {
    $departmentCodes = Get-DepartmentCodes
    foreach ($departmentCode in $departmentCodes) {
        $url = "https://geo.api.gouv.fr/departements/$departmentCode/communes?fields=code&format=geojson&geometry=contour"
        $sourceUrls.Add($url)
        foreach ($feature in (Read-FeatureCollection -Location $url)) {
            $features.Add($feature)
        }
    }
}

$seenCodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($feature in $features) {
    $code = [string]$feature.properties.code
    if ($code -notmatch '^[0-9A-Z]{5}$') {
        throw "Boundary source contains an invalid commune code '$code'."
    }
    if (-not $seenCodes.Add($code)) {
        throw "Boundary source contains duplicate commune code '$code'."
    }
    if ($null -eq $feature.geometry -or $feature.geometry.type -notin @("Polygon", "MultiPolygon")) {
        throw "Boundary source contains no polygon geometry for commune '$code'."
    }
    $rows.Add([pscustomobject]@{ code = $code; geometry = $feature.geometry })
}
if ($rows.Count -eq 0) { throw "Boundary source contains no usable commune contours." }

$payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) "import-city-boundaries-$PID.jsonl"
$payloadWriter = [System.IO.StreamWriter]::new(
    $payloadPath,
    $false,
    [System.Text.UTF8Encoding]::new($false)
)
try {
    foreach ($row in $rows) {
        $payloadWriter.WriteLine((ConvertTo-Json -InputObject $row -Compress -Depth 100))
    }
}
finally {
    $payloadWriter.Dispose()
}

$metadata = @{
    sourceUrls = $sourceUrls.ToArray()
    geometry = "contour"
    format = "geojson"
    coordinateReferenceSystem = "EPSG:4326"
    featureCount = $rows.Count
} | ConvertTo-Json -Compress -Depth 10
$metadataLiteral = ConvertTo-SqlLiteral -Value $metadata
$sourceLiteral = ConvertTo-SqlLiteral -Value $Source
$sourceUrlLiteral = ConvertTo-SqlLiteral -Value ($sourceUrls -join "`n")
$sourceYearLiteral = if ($PSBoundParameters.ContainsKey("SourceYear")) { $SourceYear.ToString() } else { "null" }

$sql = @"
\set ON_ERROR_STOP on

begin;
create temporary table city_boundary_source (payload jsonb not null) on commit drop;
copy city_boundary_source (payload) from '$containerPayloadPath';

do `$boundary_guard`$
declare
    existing_city_count integer;
    incoming_city_count integer;
    invalid_geometry_count integer;
begin
    select count(*) into existing_city_count from cities;
    select count(distinct source_rows.payload->>'code') into incoming_city_count
    from city_boundary_source source_rows
    join cities on cities.insee_code = source_rows.payload->>'code';

    if existing_city_count = 0 then
        raise exception 'No known communes are available for boundary import';
    end if;
    if incoming_city_count < ceil(existing_city_count * 0.90) then
        raise exception 'Boundary source is incomplete: % valid known contours for % communes; at least 90%% is required', incoming_city_count, existing_city_count;
    end if;

    select count(*) into invalid_geometry_count
    from city_boundary_source source_rows
    cross join lateral (
        select st_setsrid(st_multi(st_geomfromgeojson((source_rows.payload->'geometry')::text)), 4326) as geom
    ) parsed
    where parsed.geom is null or st_isempty(parsed.geom) or not st_isvalid(parsed.geom);

    if invalid_geometry_count > 0 then
        raise exception 'Boundary source contains % invalid polygon geometries', invalid_geometry_count;
    end if;
end
`$boundary_guard`$;

with source_rows as (
    select
        source_rows.payload->>'code' as code,
        st_setsrid(st_multi(st_geomfromgeojson((source_rows.payload->'geometry')::text)), 4326)::geometry(MultiPolygon, 4326) as boundary_geom
    from city_boundary_source source_rows
)
update cities
set boundary_geom = source_rows.boundary_geom,
    updated_at = now()
from source_rows
where cities.insee_code = source_rows.code
  and cities.boundary_geom is distinct from source_rows.boundary_geom;

insert into import_batches (
    source_system, source_url, source_year, status, metadata, completed_at
)
values (
    $sourceLiteral,
    $sourceUrlLiteral,
    $sourceYearLiteral,
    'completed',
    $metadataLiteral::jsonb,
    now()
);

commit;
"@

Invoke-GeneratedSql -Sql $sql -Name "import-city-boundaries" -PayloadPath $payloadPath
Write-Host "Imported $($rows.Count) official commune contours from $Source."
