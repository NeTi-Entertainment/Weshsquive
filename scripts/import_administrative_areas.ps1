param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$RegionsUrl = "https://geo.api.gouv.fr/regions?fields=nom,code",
    [string]$DepartmentsUrl = "https://geo.api.gouv.fr/departements?fields=nom,code,codeRegion",
    [string]$CitiesUrl = "https://geo.api.gouv.fr/communes?fields=nom,code,codeDepartement,codeRegion&format=json",
    [string]$Source = "geo.api.gouv.fr",
    [int]$SourceYear,
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
    if ($data.Count -eq 0) {
        throw "Received an empty JSON array from $Location"
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

$regionsJson = Read-JsonArray -Location $RegionsUrl
$departmentsJson = Read-JsonArray -Location $DepartmentsUrl
$citiesJson = Read-JsonArray -Location $CitiesUrl

$sourceLiteral = ConvertTo-SqlLiteral -Value $Source
$metadata = @{
    regionsUrl = $RegionsUrl
    departmentsUrl = $DepartmentsUrl
    citiesUrl = $CitiesUrl
} | ConvertTo-Json -Compress

$metadataLiteral = ConvertTo-SqlLiteral -Value $metadata
$sourceYearLiteral = if ($PSBoundParameters.ContainsKey("SourceYear")) { $SourceYear.ToString() } else { "null" }
$regionRowsPayload = "`$geography_regions`$`n$regionsJson`n`$geography_regions`$::jsonb"
$departmentRowsPayload = "`$geography_departments`$`n$departmentsJson`n`$geography_departments`$::jsonb"
$cityRowsPayload = "`$geography_cities`$`n$citiesJson`n`$geography_cities`$::jsonb"
$coverageGuard = @"
do `$geography_guard`$
declare
    existing_region_count integer;
    incoming_region_count integer;
    existing_department_count integer;
    incoming_department_count integer;
    existing_city_count integer;
    incoming_city_count integer;
begin
    select count(*) into existing_region_count from regions;
    select count(distinct source_regions.code) into incoming_region_count
    from jsonb_to_recordset($regionRowsPayload) as source_regions(code text, nom text)
    where source_regions.code is not null and source_regions.nom is not null;

    select count(*) into existing_department_count from departments;
    select count(distinct source_departments.code) into incoming_department_count
    from jsonb_to_recordset($departmentRowsPayload) as source_departments(code text, nom text, "codeRegion" text)
    where source_departments.code is not null
        and source_departments.nom is not null
        and exists (
            select 1
            from jsonb_to_recordset($regionRowsPayload) as source_regions(code text, nom text)
            where source_regions.code = source_departments."codeRegion"
        );

    select count(*) into existing_city_count from cities;
    select count(distinct source_cities.code) into incoming_city_count
    from jsonb_to_recordset($cityRowsPayload) as source_cities(code text, nom text, "codeDepartement" text, "codeRegion" text)
    where source_cities.code ~ '^[0-9A-Z]{5}$'
        and source_cities.nom is not null
        and exists (
            select 1
            from jsonb_to_recordset($departmentRowsPayload) as source_departments(code text, nom text, "codeRegion" text)
            where source_departments.code = source_cities."codeDepartement"
                and source_departments."codeRegion" = source_cities."codeRegion"
                and exists (
                    select 1
                    from jsonb_to_recordset($regionRowsPayload) as source_regions(code text, nom text)
                    where source_regions.code = source_departments."codeRegion"
                )
        );

    if incoming_region_count = 0 or incoming_department_count = 0 then
        raise exception 'Geography source contains no valid regions or departments';
    end if;
    if incoming_city_count = 0 then
        raise exception 'Geography source contains no valid commune rows';
    end if;
    if existing_region_count >= 10 and incoming_region_count < ceil(existing_region_count * 0.90) then
        raise exception 'Geography source is incomplete: % regions for % already known', incoming_region_count, existing_region_count;
    end if;
    if existing_department_count >= 50 and incoming_department_count < ceil(existing_department_count * 0.90) then
        raise exception 'Geography source is incomplete: % departments for % already known', incoming_department_count, existing_department_count;
    end if;
    if existing_city_count >= 1000 and incoming_city_count < ceil(existing_city_count * 0.90) then
        raise exception 'Geography source is incomplete: % valid communes for % already known', incoming_city_count, existing_city_count;
    end if;
end
`$geography_guard`$;
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
    'multiple',
    $sourceYearLiteral,
    'completed',
    $metadataLiteral::jsonb,
    now()
);

with payload(data) as (
    values (`$json`$
$regionsJson
`$json`$::jsonb)
),
rows as (
    select *
    from jsonb_to_recordset((select data from payload))
        as r(code text, nom text)
)
insert into regions (code, name, source, updated_at)
select code, nom, $sourceLiteral, now()
from rows
where code is not null and nom is not null
on conflict (code) do update
set
    name = excluded.name,
    source = excluded.source,
    updated_at = now();

with payload(data) as (
    values (`$json`$
$departmentsJson
`$json`$::jsonb)
),
rows as (
    select *
    from jsonb_to_recordset((select data from payload))
        as r(code text, nom text, "codeRegion" text)
)
insert into departments (code, name, region_code, source, updated_at)
select rows.code, rows.nom, rows."codeRegion", $sourceLiteral, now()
from rows
join regions on regions.code = rows."codeRegion"
where rows.code is not null and rows.nom is not null and rows."codeRegion" is not null
on conflict (code) do update
set
    name = excluded.name,
    region_code = excluded.region_code,
    source = excluded.source,
    updated_at = now();

with payload(data) as (
    values (`$json`$
$citiesJson
`$json`$::jsonb)
),
rows as (
    select *
    from jsonb_to_recordset((select data from payload))
        as r(code text, nom text, "codeDepartement" text, "codeRegion" text)
)
insert into cities (
    insee_code,
    name,
    department_code,
    region_code,
    source,
    updated_at
)
select rows.code, rows.nom, rows."codeDepartement", rows."codeRegion", $sourceLiteral, now()
from rows
join departments on departments.code = rows."codeDepartement"
join regions on regions.code = rows."codeRegion"
where rows.code is not null
    and rows.nom is not null
    and rows."codeDepartement" is not null
    and rows."codeRegion" is not null
on conflict (insee_code) do update
set
    name = excluded.name,
    department_code = excluded.department_code,
    region_code = excluded.region_code,
    source = excluded.source,
    updated_at = now();

commit;
"@

Invoke-GeneratedSql -Sql $sql -Name "import-administrative-areas"

if ($DeferMetricsRefresh) {
    Write-Host "Administrative import committed; derived search metric refresh was deferred."
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
        throw "Administrative data was committed, but refreshing derived search metrics failed. The previous snapshot remains active. Retry with scripts/refresh_search_metrics.ps1. Details: $($_.Exception.Message)"
    }
}

Write-Host "Administrative areas imported from $Source."
