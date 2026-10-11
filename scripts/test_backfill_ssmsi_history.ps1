param(
    [string]$DatabaseName = "app_criminalite_ssmsi_backfill_test",
    [string]$ContainerName = "app-criminalite-ssmsi-backfill-test"
)

$ErrorActionPreference = "Stop"

$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-ssmsi-backfill-fixtures-$PID"
$crimeScript = Join-Path $PSScriptRoot "import_crime_data_ssmsi.ps1"
$backfillScript = Join-Path $PSScriptRoot "backfill_ssmsi_history.ps1"

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,
        [switch]$TuplesOnly
    )

    $args = @(
        "exec", "-e", "PGPASSWORD=postgres", $ContainerName,
        "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", $DatabaseName
    )
    if ($TuplesOnly) { $args += @("-t", "-A") }
    $args += @("-c", $Sql)
    $output = docker @args
    if ($LASTEXITCODE -ne 0) { throw "psql command failed: $Sql" }
    return $output
}

function Assert-SqlEquals {
    param([string]$Sql, [string]$Expected, [string]$Message)
    $actual = (Invoke-Psql -Sql $Sql -TuplesOnly).Trim()
    if ($actual -ne $Expected) { throw "$Message. Expected '$Expected', got '$actual'." }
}

function Wait-ForPostgres {
    for ($i = 0; $i -lt 120; $i++) {
        $logs = docker logs $ContainerName 2>&1
        if (($logs -join "`n") -match "PostgreSQL init process complete") { break }
        Start-Sleep -Seconds 1
    }
    for ($i = 0; $i -lt 60; $i++) {
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select 1;" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw "PostgreSQL did not become ready in time."
}

function Invoke-Backfill {
    param([string]$SourceFile)
    & $backfillScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -CrimeFileUrl $SourceFile `
        -Years @(2016..2024) `
        -Source "test-ssmsi-backfill"
}

docker rm -f $ContainerName 2>$null | Out-Null

try {
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    $header = "CODGEO_2024;annee;indicateur;unite_de_compte;nombre;taux_pour_mille;est_diffuse;insee_pop;insee_pop_millesime;insee_log;insee_log_millesime;complement_info_nombre;complement_info_taux"
    $completeRows = @($header)
    $incompleteRows = @($header)
    foreach ($year in 2016..2025) {
        $row = "75056;$year;Cambriolages de logement;Infraction;1;2,0000000;diff;1000;2023;500;2023;NA;NA"
        $completeRows += $row
        if ($year -ne 2024) { $incompleteRows += $row }
    }
    $completeFile = Join-Path $fixtureDir "complete.csv"
    $incompleteFile = Join-Path $fixtureDir "missing-2024.csv"
    Set-Content -LiteralPath $completeFile -Value $completeRows -Encoding utf8
    Set-Content -LiteralPath $incompleteFile -Value $incompleteRows -Encoding utf8

    docker run --name $ContainerName -e POSTGRES_PASSWORD=postgres -d postgis/postgis:16-3.4 | Out-Null
    Wait-ForPostgres
    docker exec -e PGPASSWORD=postgres $ContainerName createdb -U postgres $DatabaseName

    $migrations = Get-ChildItem -Path (Join-Path $root "db/migrations") -Filter "*.sql" -File | Sort-Object Name
    foreach ($migration in $migrations) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)"
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Migration $($migration.Name) failed." }
    }

    Invoke-Psql -Sql @'
insert into regions (code, name, source) values ('11', 'Ile-de-France', 'fixture');
insert into departments (code, name, region_code, source) values ('75', 'Paris', '11', 'fixture');
insert into cities (insee_code, name, department_code, region_code, source) values ('75056', 'Paris', '75', '11', 'fixture');
'@ | Out-Null

    & $crimeScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -CrimeFileUrl $completeFile `
        -Year 2025 `
        -Source "test-ssmsi-seed" `
        -DeferMetricsRefresh
    & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    $targetYearFingerprintSql = "select md5(coalesce(string_agg(to_jsonb(cs)::text, E'\\n' order by cs.id), '')) from crime_stats cs where cs.year = 2025;"
    $targetYearFingerprint = (Invoke-Psql -Sql $targetYearFingerprintSql -TuplesOnly).Trim()
    $snapshotBefore = [long](Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()

    Invoke-Backfill -SourceFile $completeFile
    Assert-SqlEquals `
        -Sql "select count(*) || ':' || count(distinct year) from crime_stats where source = 'test-ssmsi-backfill' and year between 2016 and 2024;" `
        -Expected "9:9" `
        -Message "The backfill should import every historical year exactly once"
    Assert-SqlEquals `
        -Sql "select count(*) || ':' || min(source_year) || ':' || max(source_year) from import_batches where source_system = 'test-ssmsi-backfill';" `
        -Expected "9:2016:2024" `
        -Message "The backfill should record one import batch per year"
    Assert-SqlEquals `
        -Sql $targetYearFingerprintSql `
        -Expected $targetYearFingerprint `
        -Message "The backfill must not alter target-year raw observations"
    Assert-SqlEquals `
        -Sql "select snapshot_id - $snapshotBefore from search_metrics_active where singleton;" `
        -Expected "1" `
        -Message "A successful backfill should activate exactly one refreshed snapshot"

    $snapshotAfterFirstRun = [long](Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    Invoke-Backfill -SourceFile $completeFile
    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats where source = 'test-ssmsi-backfill' and year between 2016 and 2024;" `
        -Expected "9" `
        -Message "Rerunning the backfill must not duplicate annual observations"
    Assert-SqlEquals `
        -Sql "select snapshot_id - $snapshotAfterFirstRun from search_metrics_active where singleton;" `
        -Expected "1" `
        -Message "A successful idempotent rerun should refresh the snapshot exactly once"

    $snapshotBeforeFailure = (Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    $batchesBeforeFailure = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-ssmsi-backfill';" -TuplesOnly).Trim()
    $failureRowsBefore = (Invoke-Psql -Sql "select count(*) from crime_stats where source = 'test-ssmsi-backfill';" -TuplesOnly).Trim()
    $failed = $false
    try { Invoke-Backfill -SourceFile $incompleteFile } catch { $failed = $true }
    if (-not $failed) { throw "A backfill missing a requested year must fail." }
    Assert-SqlEquals `
        -Sql "select snapshot_id from search_metrics_active where singleton;" `
        -Expected $snapshotBeforeFailure `
        -Message "A rejected backfill must not refresh the active snapshot"
    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-ssmsi-backfill';" `
        -Expected $batchesBeforeFailure `
        -Message "A rejected backfill must not commit partial annual batches"
    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats where source = 'test-ssmsi-backfill';" `
        -Expected $failureRowsBefore `
        -Message "A rejected backfill must not commit partial crime observations"

    Write-Host "SSMSI historical backfill test passed."
}
finally {
    if (Test-Path -LiteralPath $fixtureDir) { Remove-Item -LiteralPath $fixtureDir -Recurse -Force }
    docker rm -f $ContainerName 2>$null | Out-Null
}
