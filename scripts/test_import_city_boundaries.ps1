param(
    [string]$DatabaseName = "app_criminalite_boundaries_test",
    [string]$ContainerName = "app-criminalite-boundaries-test"
)

$ErrorActionPreference = "Stop"
$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$importScript = Join-Path $PSScriptRoot "import_city_boundaries.ps1"
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-boundary-fixtures-$PID"

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [switch]$TuplesOnly
    )

    $arguments = @(
        "exec", "-e", "PGPASSWORD=postgres", $ContainerName,
        "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", $DatabaseName
    )
    if ($TuplesOnly) { $arguments += @("-t", "-A") }
    $arguments += @("-c", $Sql)
    $output = docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "psql command failed: $Sql" }
    return $output
}

function Assert-SqlEquals {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $actual = (Invoke-Psql -Sql $Sql -TuplesOnly).Trim()
    if ($actual -ne $Expected) { throw "$Message. Expected '$Expected', got '$actual'." }
}

function New-BoundaryFeature {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [double]$West = 2.0,
        [double]$South = 46.0,
        [switch]$SelfIntersecting
    )

    $westText = $West.ToString("0.000000", [Globalization.CultureInfo]::InvariantCulture)
    $southText = $South.ToString("0.000000", [Globalization.CultureInfo]::InvariantCulture)
    $eastText = ($West + 0.01).ToString("0.000000", [Globalization.CultureInfo]::InvariantCulture)
    $northText = ($South + 0.01).ToString("0.000000", [Globalization.CultureInfo]::InvariantCulture)

    if ($SelfIntersecting) {
        $ring = "[[$westText,$southText],[$eastText,$northText],[$westText,$northText],[$eastText,$southText],[$westText,$southText]]"
    }
    else {
        $ring = "[[$westText,$southText],[$westText,$northText],[$eastText,$northText],[$eastText,$southText],[$westText,$southText]]"
    }

    return "{`"type`":`"Feature`",`"properties`":{`"code`":`"$Code`"},`"geometry`":{`"type`":`"MultiPolygon`",`"coordinates`":[[$ring]]}}"
}

function Write-FeatureCollection {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Features
    )

    $json = "{`"type`":`"FeatureCollection`",`"features`":[$($Features -join ',')]}"
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-ImportRejected {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    try {
        & $importScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -SourceUrl $SourcePath `
            -SourceYear 2026
    }
    catch { return }

    throw "Boundary import should reject '$SourcePath'."
}

docker rm -f $ContainerName 2>$null | Out-Null

try {
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    docker run --name $ContainerName -e POSTGRES_PASSWORD=postgres -d postgis/postgis:16-3.4 | Out-Null

    $initComplete = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $logs = docker logs $ContainerName 2>&1
        if (($logs -join "`n") -match "PostgreSQL init process complete") {
            $initComplete = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $initComplete) { throw "PostgreSQL container initialization did not complete in time." }

    $ready = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select 1;" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "PostgreSQL did not become ready in time." }

    docker exec -e PGPASSWORD=postgres $ContainerName createdb -U postgres $DatabaseName
    foreach ($migration in (Get-ChildItem -Path $migrationDir -Filter "*.sql" -File | Sort-Object Name)) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not copy migration $($migration.Name)." }
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($migration.Name)." }
    }

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name='cities' and column_name='boundary_geom' and udt_name='geometry';" `
        -Expected "1" `
        -Message "Migration must add the boundary geometry column"
    Assert-SqlEquals `
        -Sql "select count(*) from pg_indexes where tablename='cities' and indexdef ilike '%using gist (boundary_geom)%';" `
        -Expected "1" `
        -Message "Migration must add the spatial GiST index"
    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name='cities' and column_name in ('latitude','longitude','geom');" `
        -Expected "3" `
        -Message "Migration must preserve point coordinates"

    Invoke-Psql -Sql @"
insert into regions (code, name, source) values ('84', 'Auvergne-Rhone-Alpes', 'fixture');
insert into departments (code, name, region_code, source) values ('01', 'Ain', '84', 'fixture');
insert into cities (insee_code, name, department_code, region_code, latitude, longitude, source)
select lpad((10000 + series.number)::text, 5, '0'), 'Commune ' || series.number, '01', '84', 46, 2, 'fixture'
from generate_series(1, 1002) as series(number);
"@ | Out-Null

    $completeFeatures = [System.Collections.Generic.List[string]]::new()
    for ($number = 1; $number -le 1002; $number++) {
        $code = "{0:D5}" -f (10000 + $number)
        $completeFeatures.Add((New-BoundaryFeature -Code $code))
    }
    $completePath = Join-Path $fixtureDir "boundaries-complete.geojson"
    Write-FeatureCollection -Path $completePath -Features $completeFeatures.ToArray()

    & $importScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -SourceUrl $completePath `
        -SourceYear 2026

    docker exec $ContainerName sh -lc 'files=$(find /tmp -maxdepth 1 -name "import-city-boundaries-*.jsonl" -print -quit); test -z "$files" && test ! -e /tmp/import-city-boundaries.sql'
    if ($LASTEXITCODE -ne 0) { throw "Boundary importer must remove its temporary SQL and JSONL files." }

    Assert-SqlEquals `
        -Sql "select count(*) from cities where boundary_geom is not null and st_srid(boundary_geom)=4326 and st_geometrytype(boundary_geom)='ST_MultiPolygon' and st_isvalid(boundary_geom);" `
        -Expected "1002" `
        -Message "Complete import should write valid WGS84 MultiPolygons"
    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system='geo.api.gouv.fr-city-boundaries' and status='completed';" `
        -Expected "1" `
        -Message "Successful import should record one completed batch"

    & $importScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -SourceUrl $completePath `
        -SourceYear 2026
    Assert-SqlEquals `
        -Sql "select count(*) from cities where boundary_geom is not null;" `
        -Expected "1002" `
        -Message "Re-import must not duplicate or remove boundaries"

    $partialFeatures = [System.Collections.Generic.List[string]]::new()
    for ($number = 1; $number -le 899; $number++) {
        $code = "{0:D5}" -f (10000 + $number)
        $feature = if ($number -eq 1) { New-BoundaryFeature -Code $code -West 3.0 -South 47.0 } else { New-BoundaryFeature -Code $code }
        $partialFeatures.Add($feature)
    }
    $partialPath = Join-Path $fixtureDir "boundaries-partial.geojson"
    Write-FeatureCollection -Path $partialPath -Features $partialFeatures.ToArray()
    Invoke-ImportRejected -SourcePath $partialPath
    Assert-SqlEquals `
        -Sql "select round(st_x(st_centroid(boundary_geom))::numeric,3)::text from cities where insee_code='10001';" `
        -Expected "2.005" `
        -Message "Rejected partial import must not change existing geometry"
    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system='geo.api.gouv.fr-city-boundaries' and status='completed';" `
        -Expected "2" `
        -Message "Rejected import must not record a completed batch"

    $duplicateFeatures = @((New-BoundaryFeature -Code "10001"), (New-BoundaryFeature -Code "10001"))
    $duplicatePath = Join-Path $fixtureDir "boundaries-duplicate.geojson"
    Write-FeatureCollection -Path $duplicatePath -Features $duplicateFeatures
    Invoke-ImportRejected -SourcePath $duplicatePath

    $invalidFeatures = @((New-BoundaryFeature -Code "10001" -SelfIntersecting))
    $invalidPath = Join-Path $fixtureDir "boundaries-invalid.geojson"
    Write-FeatureCollection -Path $invalidPath -Features $invalidFeatures
    Invoke-ImportRejected -SourcePath $invalidPath

    $emptyPath = Join-Path $fixtureDir "boundaries-empty.geojson"
    Write-FeatureCollection -Path $emptyPath -Features @()
    Invoke-ImportRejected -SourcePath $emptyPath

    $malformedPath = Join-Path $fixtureDir "boundaries-malformed.geojson"
    [System.IO.File]::WriteAllText($malformedPath, "{invalid", [System.Text.UTF8Encoding]::new($false))
    Invoke-ImportRejected -SourcePath $malformedPath

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system='geo.api.gouv.fr-city-boundaries' and status='completed';" `
        -Expected "2" `
        -Message "Invalid inputs must never record a completed import batch"
    Assert-SqlEquals `
        -Sql "select count(*) from cities where geom is not null and latitude=46 and longitude=2;" `
        -Expected "1002" `
        -Message "Boundary imports must not alter existing point coordinates"

    Write-Host "City boundary import test passed."
}
finally {
    if (Test-Path -LiteralPath $fixtureDir) {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force
    }
    docker rm -f $ContainerName 2>$null | Out-Null
}
