param(
    [string]$DatabaseName = "app_criminalite_import_test",
    [string]$ContainerName = "app-criminalite-import-test"
)

$ErrorActionPreference = "Stop"

$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$importScript = Join-Path $PSScriptRoot "import_administrative_areas.ps1"
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-import-fixtures-$PID"

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,
        [switch]$TuplesOnly
    )

    $args = @(
        "exec", "-e", "PGPASSWORD=postgres", $ContainerName,
        "psql", "-v", "ON_ERROR_STOP=1",
        "-U", "postgres", "-d", $DatabaseName
    )

    if ($TuplesOnly) {
        $args += @("-t", "-A")
    }

    $args += @("-c", $Sql)
    $output = docker @args
    if ($LASTEXITCODE -ne 0) {
        throw "psql command failed: $Sql"
    }

    return $output
}

function Assert-SqlEquals {
    param(
        [string]$Sql,
        [string]$Expected,
        [string]$Message
    )

    $actual = (Invoke-Psql -Sql $Sql -TuplesOnly).Trim()
    if ($actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$actual'."
    }
}

function Wait-ForPostgres {
    $initComplete = $false
    for ($i = 0; $i -lt 120; $i++) {
        $logs = docker logs $ContainerName 2>&1
        if (($logs -join "`n") -match "PostgreSQL init process complete") {
            $initComplete = $true
            break
        }
        Start-Sleep -Seconds 1
    }

    if (-not $initComplete) {
        throw "PostgreSQL container initialization did not complete in time."
    }

    for ($i = 0; $i -lt 60; $i++) {
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select 1;" `
            2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds 1
    }

    throw "PostgreSQL did not become ready in time."
}

function Apply-Migrations {
    $migrationFiles = Get-ChildItem -Path $migrationDir -Filter "*.sql" -File | Sort-Object Name
    foreach ($migration in $migrationFiles) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)"
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" `
            | Out-Null
    }
}

docker rm -f $ContainerName 2>$null | Out-Null

try {
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

    @'
[
  {"code":"11","nom":"Ile-de-France"},
  {"code":"84","nom":"Auvergne-Rhone-Alpes"}
]
'@ | Set-Content -Path (Join-Path $fixtureDir "regions.json") -Encoding utf8

    @'
[
  {"code":"75","nom":"Paris","codeRegion":"11"},
  {"code":"69","nom":"Rhone","codeRegion":"84"}
]
'@ | Set-Content -Path (Join-Path $fixtureDir "departments.json") -Encoding utf8

    @'
[
  {"code":"75056","nom":"Paris","codeDepartement":"75","codeRegion":"11","population":2133111},
  {"code":"69123","nom":"Lyon","codeDepartement":"69","codeRegion":"84","population":522250},
  {"code":"97502","nom":"Saint-Pierre","codeDepartement":"975","codeRegion":"975","population":5394}
]
'@ | Set-Content -Path (Join-Path $fixtureDir "cities.json") -Encoding utf8

    @'
[]
'@ | Set-Content -Path (Join-Path $fixtureDir "cities-empty.json") -Encoding utf8

    docker run `
        --name $ContainerName `
        -e POSTGRES_PASSWORD=postgres `
        -d postgis/postgis:16-3.4 `
        | Out-Null

    Wait-ForPostgres

    docker exec -e PGPASSWORD=postgres $ContainerName `
        createdb -U postgres $DatabaseName

    Apply-Migrations

    & $importScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -RegionsUrl (Join-Path $fixtureDir "regions.json") `
        -DepartmentsUrl (Join-Path $fixtureDir "departments.json") `
        -CitiesUrl (Join-Path $fixtureDir "cities.json") `
        -Source "test-geo-api" `
        -SourceYear 2026

    & $importScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -RegionsUrl (Join-Path $fixtureDir "regions.json") `
        -DepartmentsUrl (Join-Path $fixtureDir "departments.json") `
        -CitiesUrl (Join-Path $fixtureDir "cities.json") `
        -Source "test-geo-api" `
        -SourceYear 2026 `
        -DeferMetricsRefresh

    Assert-SqlEquals `
        -Sql "select snapshot_id from search_metrics_active where singleton;" `
        -Expected "1" `
        -Message "Deferred administrative imports should leave the active metrics snapshot unchanged"

    & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    Assert-SqlEquals `
        -Sql "select count(*) from regions;" `
        -Expected "2" `
        -Message "Regions import should be idempotent"

    Assert-SqlEquals `
        -Sql "select count(*) from departments;" `
        -Expected "2" `
        -Message "Departments import should be idempotent"

    Assert-SqlEquals `
        -Sql "select count(*) from cities;" `
        -Expected "2" `
        -Message "Cities import should be idempotent"

    Assert-SqlEquals `
        -Sql "select d.region_code from departments d where d.code = '75';" `
        -Expected "11" `
        -Message "Department should be attached to its region"

    Assert-SqlEquals `
        -Sql "select department_code || ':' || region_code || ':' || (reference_population is null)::text || ':' || (population_year is null)::text from cities where insee_code = '75056';" `
        -Expected "75:11:true:true" `
        -Message "City should keep INSEE code and parent codes without importing population before the INSEE population step"

    Assert-SqlEquals `
        -Sql "select count(*) from search_metric_snapshots;" `
        -Expected "2" `
        -Message "A deferred administrative import should allow one final metrics refresh"

    $batchCountBeforeEmptySource = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-geo-api';" -TuplesOnly).Trim()
    $emptyGeographyFailed = $false
    try {
        & $importScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -RegionsUrl (Join-Path $fixtureDir "regions.json") `
            -DepartmentsUrl (Join-Path $fixtureDir "departments.json") `
            -CitiesUrl (Join-Path $fixtureDir "cities-empty.json") `
            -Source "test-geo-api" `
            -SourceYear 2026 `
            -DeferMetricsRefresh
    }
    catch {
        $emptyGeographyFailed = $true
    }

    if (-not $emptyGeographyFailed) {
        throw "An empty geography source should fail before replacing the current reference."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-geo-api';" `
        -Expected $batchCountBeforeEmptySource `
        -Message "An empty geography source must not create a completed import batch"

    Invoke-Psql -Sql @"
insert into cities (insee_code, name, department_code, region_code, source)
select lpad((10000 + series.number)::text, 5, '0'), 'Fixture ' || series.number, '75', '11', 'fixture'
from generate_series(1, 1000) as series(number);
"@ | Out-Null

    $batchCountBeforePartialSource = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-geo-api';" -TuplesOnly).Trim()
    $partialGeographyFailed = $false
    try {
        & $importScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -RegionsUrl (Join-Path $fixtureDir "regions.json") `
            -DepartmentsUrl (Join-Path $fixtureDir "departments.json") `
            -CitiesUrl (Join-Path $fixtureDir "cities.json") `
            -Source "test-geo-api" `
            -SourceYear 2026 `
            -DeferMetricsRefresh
    }
    catch {
        $partialGeographyFailed = $true
    }

    if (-not $partialGeographyFailed) {
        throw "A geography source covering only a small part of a populated database should fail."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-geo-api';" `
        -Expected $batchCountBeforePartialSource `
        -Message "An incomplete geography source must not create a completed import batch"

    Write-Host "Administrative areas import test passed."
}
finally {
    if (Test-Path $fixtureDir) {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force
    }
    docker rm -f $ContainerName 2>$null | Out-Null
}
