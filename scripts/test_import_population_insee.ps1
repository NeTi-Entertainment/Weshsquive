param(
    [string]$DatabaseName = "app_criminalite_population_test",
    [string]$ContainerName = "app-criminalite-population-test"
)

$ErrorActionPreference = "Stop"

$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$populationScript = Join-Path $PSScriptRoot "import_population_insee.ps1"
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-population-fixtures-$PID"

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
REG;Région;DEP;CODARR;CODCAN;CODCOM;COM;Commune;PMUN;PCAP;PTOT
11;Ile-de-France;75;1;;101;75101;Paris 1er Arrondissement;15114;93;15207
11;Ile-de-France;75;1;;102;75102;Paris 2e Arrondissement;19847;132;19979
84;Auvergne-Rhone-Alpes;69;1;00;381;69381;Lyon 1er Arrondissement;28717;856;29573
84;Auvergne-Rhone-Alpes;69;1;00;382;69382;Lyon 2e Arrondissement;29981;344;30325
99;Unknown;99;1;01;999;99999;Commune absente;1234;0;1234
'@ | Set-Content -Path (Join-Path $fixtureDir "donnees_communes_2023.csv") -Encoding utf8

    @'
REG;Région;DEP;CODARR;CODCAN;CODCOM;COM;Commune;PMUN;PCAP;PTOT
11;Ile-de-France;75;1;;101;75101;Paris 1er Arrondissement;16000;93;16093
11;Ile-de-France;75;1;;102;75102;Paris 2e Arrondissement;20000;132;20132
84;Auvergne-Rhone-Alpes;69;1;00;381;69381;Lyon 1er Arrondissement;29000;856;29856
84;Auvergne-Rhone-Alpes;69;1;00;382;69382;Lyon 2e Arrondissement;30000;344;30344
'@ | Set-Content -Path (Join-Path $fixtureDir "donnees_communes_2024.csv") -Encoding utf8

    @'
"GEO";"GEO_OBJECT";"FREQ";"POPREF_MEASURE";"TIME_PERIOD";"OBS_VALUE"
"75056";"COM";"A";"PMUN";2025;2200000
"75056";"COM";"A";"PCAP";2025;16000
"75101";"ARM";"A";"PMUN";2025;16000
"69123";"COM";"A";"PMUN";2025;600000
"69123";"COM";"A";"PMUN";2024;590000
"69123";"COM";"A";"PTOT";2025;605000
'@ | Set-Content -Path (Join-Path $fixtureDir "DS_POPULATIONS_REFERENCE_2025_data.csv") -Encoding utf8
    Compress-Archive `
        -LiteralPath (Join-Path $fixtureDir "DS_POPULATIONS_REFERENCE_2025_data.csv") `
        -DestinationPath (Join-Path $fixtureDir "insee-populations-2025.zip")

    @'
"GEO";"GEO_OBJECT";"FREQ";"POPREF_MEASURE";"TIME_PERIOD";"OBS_VALUE"
"75056";"COM";"A";"PMUN";2025;2250000
'@ | Set-Content -Path (Join-Path $fixtureDir "DS_POPULATIONS_REFERENCE_2025_revision.csv") -Encoding utf8

    @'
"GEO";"GEO_OBJECT";"FREQ";"POPREF_MEASURE";"TIME_PERIOD";"OBS_VALUE"
"75056";"COM";"A";"PTOT";2025;2250000
'@ | Set-Content -Path (Join-Path $fixtureDir "DS_POPULATIONS_REFERENCE_2025_empty.csv") -Encoding utf8

    docker run `
        --name $ContainerName `
        -e POSTGRES_PASSWORD=postgres `
        -d postgis/postgis:16-3.4 `
        | Out-Null

    Wait-ForPostgres

    docker exec -e PGPASSWORD=postgres $ContainerName `
        createdb -U postgres $DatabaseName

    Apply-Migrations

    Invoke-Psql -Sql @"
insert into regions (code, name, source)
values ('11', 'Ile-de-France', 'fixture'), ('84', 'Auvergne-Rhone-Alpes', 'fixture');

insert into departments (code, name, region_code, source)
values ('75', 'Paris', '11', 'fixture'), ('69', 'Rhone', '84', 'fixture');

insert into cities (insee_code, name, department_code, region_code, source)
values
    ('75056', 'Paris', '75', '11', 'fixture'),
    ('69123', 'Lyon', '69', '84', 'fixture');
"@ | Out-Null

    & $populationScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -PopulationFileUrl (Join-Path $fixtureDir "donnees_communes_2023.csv") `
        -PopulationYear 2023 `
        -Source "test-insee-population"

    & $populationScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -PopulationFileUrl (Join-Path $fixtureDir "donnees_communes_2023.csv") `
        -PopulationYear 2023 `
        -Source "test-insee-population"

    Assert-SqlEquals `
        -Sql "select count(*) from population_history;" `
        -Expected "2" `
        -Message "Population import should be idempotent and skip unknown cities"

    Assert-SqlEquals `
        -Sql "select reference_population || ':' || population_year from cities where insee_code = '75056';" `
        -Expected "34961:2023" `
        -Message "City should cache imported reference population, including PLM arrondissement aggregation"

    Assert-SqlEquals `
        -Sql "select population from population_history where city_insee_code = '69123' and year = 2023;" `
        -Expected "58698" `
        -Message "Population history should store municipal population, including PLM arrondissement aggregation"

    & $populationScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -PopulationFileUrl (Join-Path $fixtureDir "donnees_communes_2024.csv") `
        -PopulationYear 2024 `
        -Source "test-insee-population"

    Assert-SqlEquals `
        -Sql "select count(*) from population_history;" `
        -Expected "4" `
        -Message "A new year should append history without overwriting prior years"

    Assert-SqlEquals `
        -Sql "select reference_population || ':' || population_year from cities where insee_code = '75056';" `
        -Expected "36000:2024" `
        -Message "City reference population should update to the latest imported year"

    $snapshotBeforeDeferredImport = (Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    & $populationScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -PopulationFileUrl (Join-Path $fixtureDir "insee-populations-2025.zip") `
        -PopulationYear 2025 `
        -Source "test-insee-population" `
        -SourceLastModified "2026-05-29T08:59:41+02:00" `
        -DeferMetricsRefresh

    Assert-SqlEquals `
        -Sql "select snapshot_id from search_metrics_active where singleton;" `
        -Expected $snapshotBeforeDeferredImport `
        -Message "A deferred Insee import should leave the previous metrics snapshot active"

    & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    Assert-SqlEquals `
        -Sql "select count(*) from population_history;" `
        -Expected "6" `
        -Message "The modern Insee archive should import one municipal population row per known city"

    Assert-SqlEquals `
        -Sql "select population from population_history where city_insee_code = '75056' and year = 2025;" `
        -Expected "2200000" `
        -Message "The modern Insee archive should import municipal population, not population plus separate arrondissements"

    Assert-SqlEquals `
        -Sql "select population from population_history where city_insee_code = '69123' and year = 2025;" `
        -Expected "600000" `
        -Message "The modern Insee archive should select PMUN for the requested year, not PTOT or another year"

    Assert-SqlEquals `
        -Sql "select metadata->>'catalogLastModified' from import_batches where source_system = 'test-insee-population' and source_year = 2025 order by completed_at desc limit 1;" `
        -Expected "2026-05-29T08:59:41+02:00" `
        -Message "Insee import metadata should retain the official catalog revision timestamp"

    & $populationScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -PopulationFileUrl (Join-Path $fixtureDir "DS_POPULATIONS_REFERENCE_2025_revision.csv") `
        -PopulationYear 2025 `
        -Source "test-insee-population" `
        -DeferMetricsRefresh

    Assert-SqlEquals `
        -Sql "select count(*) from population_history where city_insee_code = '69123' and year = 2025;" `
        -Expected "0" `
        -Message "A revised Insee release should remove observations absent from that source revision"

    Assert-SqlEquals `
        -Sql "select population from population_history where city_insee_code = '75056' and year = 2025;" `
        -Expected "2250000" `
        -Message "A revised Insee release should replace remaining observations"

    $emptyPopulationRevisionFailed = $false
    try {
        & $populationScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -PopulationFileUrl (Join-Path $fixtureDir "DS_POPULATIONS_REFERENCE_2025_empty.csv") `
            -PopulationYear 2025 `
            -Source "test-insee-population" `
            -DeferMetricsRefresh
    }
    catch {
        $emptyPopulationRevisionFailed = $true
    }

    if (-not $emptyPopulationRevisionFailed) {
        throw "An Insee revision without municipal population observations should fail before replacing the year."
    }

    Assert-SqlEquals `
        -Sql "select population from population_history where city_insee_code = '75056' and year = 2025;" `
        -Expected "2250000" `
        -Message "An empty Insee revision must leave the previously imported year intact"

    Assert-SqlEquals `
        -Sql "select reference_population || ':' || population_year from cities where insee_code = '69123';" `
        -Expected "59000:2024" `
        -Message "Removing a revised current-year observation should restore the latest remaining population cache"

    $populationBatchCount = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-insee-population';" -TuplesOnly).Trim()
    $missingPopulationYearFailed = $false
    try {
        & $populationScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -PopulationFileUrl (Join-Path $fixtureDir "insee-populations-2025.zip") `
            -PopulationYear 2026 `
            -Source "test-insee-population"
    }
    catch {
        $missingPopulationYearFailed = $true
    }

    if (-not $missingPopulationYearFailed) {
        throw "A population archive without the requested year should fail before import."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-insee-population';" `
        -Expected $populationBatchCount `
        -Message "A missing population year must not create an import batch"

    Assert-SqlEquals `
        -Sql "select count(*) from search_metric_snapshots;" `
        -Expected "2" `
        -Message "Population imports should refresh metrics and retain only two generations"

    Invoke-Psql -Sql @"
insert into cities (insee_code, name, department_code, region_code, source)
select lpad((10000 + series.number)::text, 5, '0'), 'Fixture ' || series.number, '75', '11', 'fixture'
from generate_series(1, 1000) as series(number);
"@ | Out-Null

    $batchCountBeforePartialSource = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-insee-population';" -TuplesOnly).Trim()
    $partialPopulationRevisionFailed = $false
    try {
        & $populationScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -PopulationFileUrl (Join-Path $fixtureDir "DS_POPULATIONS_REFERENCE_2025_revision.csv") `
            -PopulationYear 2025 `
            -Source "test-insee-population" `
            -DeferMetricsRefresh
    }
    catch {
        $partialPopulationRevisionFailed = $true
    }

    if (-not $partialPopulationRevisionFailed) {
        throw "An Insee release covering only a small part of a populated database should fail."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-insee-population';" `
        -Expected $batchCountBeforePartialSource `
        -Message "An incomplete Insee revision must not create a completed import batch"

    Assert-SqlEquals `
        -Sql "select population from population_history where city_insee_code = '75056' and year = 2025;" `
        -Expected "2250000" `
        -Message "An incomplete Insee revision must leave the prior annual data intact"

    Write-Host "INSEE population import test passed."
}
finally {
    if (Test-Path $fixtureDir) {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force
    }
    docker rm -f $ContainerName 2>$null | Out-Null
}
