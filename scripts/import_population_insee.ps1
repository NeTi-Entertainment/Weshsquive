param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$PopulationFileUrl = "https://www.insee.fr/fr/statistiques/fichier/8680726/ensemble.zip",
    [int]$PopulationYear = 2023,
    [string]$Source = "insee-populations-reference",
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

function Resolve-PopulationCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Location,
        [Parameter(Mandatory = $true)]
        [string]$WorkDir,
        [Parameter(Mandatory = $true)]
        [int]$Year
    )

    function Find-PopulationCsvInDirectory {
        param([Parameter(Mandatory = $true)][string]$Directory)

        $legacyCsv = Get-ChildItem -Path $Directory -Recurse -Filter "donnees_communes.csv" -File |
            Select-Object -First 1
        if ($null -ne $legacyCsv) {
            return $legacyCsv.FullName
        }

        $harmonizedCsv = Get-ChildItem -Path $Directory -Recurse -Filter "DS_POPULATIONS_REFERENCE_${Year}_data.csv" -File |
            Select-Object -First 1
        if ($null -ne $harmonizedCsv) {
            return $harmonizedCsv.FullName
        }

        return $null
    }

    if (Test-Path -LiteralPath $Location -PathType Leaf) {
        if ([System.IO.Path]::GetExtension($Location).ToLowerInvariant() -eq ".zip") {
            Expand-Archive -Path $Location -DestinationPath $WorkDir -Force
            return Find-PopulationCsvInDirectory -Directory $WorkDir
        }

        return (Resolve-Path -LiteralPath $Location).Path
    }

    if (Test-Path -LiteralPath $Location -PathType Container) {
        return Find-PopulationCsvInDirectory -Directory $Location
    }

    $downloadPath = Join-Path $WorkDir "population-source.zip"
    Invoke-WebRequest -Uri $Location -OutFile $downloadPath
    Expand-Archive -Path $downloadPath -DestinationPath $WorkDir -Force

    $csvPath = Find-PopulationCsvInDirectory -Directory $WorkDir
    if ([string]::IsNullOrWhiteSpace($csvPath)) {
        throw "No donnees_communes.csv found in $Location"
    }

    return $csvPath
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

function Get-CommuneInseeCode {
    param([Parameter(Mandatory = $true)][string]$Code)

    if ($Code -match '^751(0[1-9]|1[0-9]|20)$') {
        return "75056"
    }

    if ($Code -match '^6938[1-9]$') {
        return "69123"
    }

    if ($Code -match '^132(0[1-9]|1[0-6])$') {
        return "13055"
    }

    return $Code
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-insee-population-$PID"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    $csvPath = Resolve-PopulationCsv -Location $PopulationFileUrl -WorkDir $workDir -Year $PopulationYear
    if ([string]::IsNullOrWhiteSpace($csvPath) -or -not (Test-Path -LiteralPath $csvPath)) {
        throw "Population CSV not found from $PopulationFileUrl"
    }

    $firstRow = Import-Csv -LiteralPath $csvPath -Delimiter ';' | Select-Object -First 1
    if ($null -eq $firstRow) {
        throw "No population data rows found in $csvPath"
    }

    $isHarmonized = $firstRow.PSObject.Properties.Name -contains "GEO_OBJECT"
    if ($isHarmonized) {
        $populationByCode = @{}
        foreach ($row in Import-Csv -LiteralPath $csvPath -Delimiter ';') {
            if ($row.GEO_OBJECT -ne "COM" `
                    -or $row.FREQ -ne "A" `
                    -or $row.POPREF_MEASURE -ne "PMUN" `
                    -or [string]$row.TIME_PERIOD -ne [string]$PopulationYear) {
                continue
            }

            if ($row.GEO -notmatch '^[0-9A-Z]{5}$' -or $row.OBS_VALUE -notmatch '^\d+$') {
                continue
            }

            $code = Get-CommuneInseeCode -Code $row.GEO
            if ($populationByCode.ContainsKey($code)) {
                throw "Duplicate municipal population rows for commune $code in $csvPath"
            }

            $populationByCode[$code] = [int]$row.OBS_VALUE
        }

        $rows = @(
            $populationByCode.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ code = $_.Key; population = $_.Value }
            }
        )
    }
    else {
        $rawRows = Import-Csv -LiteralPath $csvPath -Delimiter ';' |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.COM) `
                    -and $_.COM.Length -eq 5 `
                    -and $_.PMUN -match '^\d+$'
            } |
            Select-Object @{
                Name = "code";
                Expression = { Get-CommuneInseeCode -Code $_.COM }
            }, @{
                Name = "population";
                Expression = { [int]$_.PMUN }
            }

        $rows = @(
            $rawRows |
                Group-Object -Property code |
                ForEach-Object {
                    [pscustomobject]@{
                        code = $_.Name
                        population = [int](($_.Group | Measure-Object -Property population -Sum).Sum)
                    }
                }
        )
    }

    if (@($rows).Count -eq 0) {
        throw "No commune population rows found in $csvPath"
    }

    $rowsJson = ConvertTo-Json -InputObject @($rows) -Compress -Depth 10
    $sourceLiteral = ConvertTo-SqlLiteral -Value $Source
    $sourceUrlLiteral = ConvertTo-SqlLiteral -Value $PopulationFileUrl
    $metadataLiteral = ConvertTo-SqlLiteral -Value (@{
        populationFileUrl = $PopulationFileUrl
        importedMeasure = "PMUN"
        importedMeasureLabel = "Population municipale"
        catalogLastModified = $SourceLastModified
    } | ConvertTo-Json -Compress)
    $populationRowsPayload = "`$population_rows`$`n$rowsJson`n`$population_rows`$::jsonb"
    $coverageGuard = @"
do `$population_guard`$
declare
    existing_city_count integer;
    incoming_city_count integer;
begin
    select count(*) into existing_city_count from cities;
    select count(distinct source_rows.code) into incoming_city_count
    from jsonb_to_recordset($populationRowsPayload) as source_rows(code text, population integer)
    join cities on cities.insee_code = source_rows.code;

    if incoming_city_count = 0 then
        raise exception 'Insee source contains no known municipal population rows for year $PopulationYear';
    end if;
    if existing_city_count >= 1000 and incoming_city_count < ceil(existing_city_count * 0.90) then
        raise exception 'Insee source is incomplete: % known communes for % already known', incoming_city_count, existing_city_count;
    end if;
end
`$population_guard`$;
"@

    $sql = @"
\set ON_ERROR_STOP on

begin;

$coverageGuard

delete from population_history
where source = $sourceLiteral
    and year = $PopulationYear;

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
        $PopulationYear,
        'completed',
        $metadataLiteral::jsonb,
        now()
    )
    returning id
),
payload(data) as (
    values (`$json`$
$rowsJson
`$json`$::jsonb)
),
rows as (
    select *
    from jsonb_to_recordset((select data from payload))
        as r(code text, population integer)
),
known_city_rows as (
    select rows.code, rows.population
    from rows
    join cities on cities.insee_code = rows.code
)
insert into population_history (
    city_insee_code,
    year,
    population,
    source,
    import_batch_id,
    imported_at
)
select
    code,
    $PopulationYear,
    population,
    $sourceLiteral,
    (select id from import_batch),
    now()
from known_city_rows
on conflict (city_insee_code, year, source) do update
set
    population = excluded.population,
    import_batch_id = excluded.import_batch_id,
    imported_at = now();

with payload(data) as (
    values (`$json`$
$rowsJson
`$json`$::jsonb)
),
rows as (
    select *
    from jsonb_to_recordset((select data from payload))
        as r(code text, population integer)
)
update cities
set
    reference_population = rows.population,
    population_year = $PopulationYear,
    updated_at = now()
from rows
where cities.insee_code = rows.code
    and (
        cities.population_year is null
        or cities.population_year <= $PopulationYear
    );

with payload(data) as (
    values (`$json`$
$rowsJson
`$json`$::jsonb)
),
source_rows as (
    select *
    from jsonb_to_recordset((select data from payload))
        as r(code text, population integer)
)
update cities
set
    reference_population = (
        select history.population
        from population_history history
        where history.city_insee_code = cities.insee_code
        order by history.year desc, history.imported_at desc
        limit 1
    ),
    population_year = (
        select history.year
        from population_history history
        where history.city_insee_code = cities.insee_code
        order by history.year desc, history.imported_at desc
        limit 1
    ),
    updated_at = now()
where cities.population_year = $PopulationYear
    and not exists (
        select 1 from source_rows where source_rows.code = cities.insee_code
    );

commit;
"@

    Invoke-GeneratedSql -Sql $sql -Name "import-population-insee"

    if ($DeferMetricsRefresh) {
        Write-Host "Population import committed; derived search metric refresh was deferred."
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
            throw "Population data was committed, but refreshing derived search metrics failed. The previous snapshot remains active. Retry with scripts/refresh_search_metrics.ps1. Details: $($_.Exception.Message)"
        }
    }

    Write-Host "INSEE population imported for $PopulationYear from $Source."
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
}
