param(
    [string]$DatabaseName = "app_criminalite_test",
    [string]$ContainerName = "app-criminalite-schema-test"
)

$ErrorActionPreference = "Stop"

$ContainerName = "$ContainerName-$PID"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$migrationFiles = Get-ChildItem -Path $migrationDir -Filter "*.sql" -File | Sort-Object Name

if ($migrationFiles.Count -eq 0) {
    throw "No SQL migrations found in $migrationDir"
}

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,
        [string]$TargetDatabase = $DatabaseName,
        [switch]$TuplesOnly
    )

    $args = @(
        "exec", "-e", "PGPASSWORD=postgres", $ContainerName,
        "psql", "-v", "ON_ERROR_STOP=1",
        "-U", "postgres", "-d", $TargetDatabase
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

docker rm -f $ContainerName 2>$null | Out-Null

try {
    docker run `
        --name $ContainerName `
        -e POSTGRES_PASSWORD=postgres `
        -d postgis/postgis:16-3.4 `
        | Out-Null

    $initComplete = $false
    for ($i = 0; $i -lt 120; $i++) {
        $strictPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $logs = docker logs $ContainerName 2>&1
        $ErrorActionPreference = $strictPreference
        if (($logs -join "`n") -match "PostgreSQL init process complete") {
            $initComplete = $true
            break
        }
        Start-Sleep -Seconds 1
    }

    if (-not $initComplete) {
        throw "PostgreSQL container initialization did not complete in time."
    }

    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select 1;" `
            2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }

    if (-not $ready) {
        throw "PostgreSQL did not become ready in time."
    }

    docker exec -e PGPASSWORD=postgres $ContainerName `
        createdb -U postgres $DatabaseName

    foreach ($migration in $migrationFiles) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)"
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" `
            | Out-Null
    }

    Assert-SqlEquals `
        -Sql "select count(*) from pg_extension where extname in ('postgis','postgis_topology');" `
        -Expected "2" `
        -Message "PostGIS extensions are not installed"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.tables where table_schema = 'public' and table_name in ('regions','departments','cities','crime_categories','crime_stats','population_history','import_batches','search_metric_snapshots','search_metrics_active','search_metrics_city_year_category','search_metrics_city_year_comparative','property_sale_observations','property_rent_observations','property_market_metrics');" `
        -Expected "14" `
        -Message "Core and derived search metric tables are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_constraint where conname in ('property_sale_observations_pkey','property_rent_observations_pkey','property_market_metrics_pkey','property_market_metric_type_check','property_market_publication_check');" `
        -Expected "5" `
        -Message "Property market idempotence and publication constraints are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_indexes where indexname in ('property_sale_city_year_type_idx','property_rent_city_year_type_idx','property_market_lookup_idx');" `
        -Expected "3" `
        -Message "Property market lookup indexes are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name = 'cities' and column_name in ('insee_code','name','department_code','region_code','latitude','longitude','geom','reference_population','population_year');" `
        -Expected "9" `
        -Message "cities does not expose the expected stable commune fields"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name = 'crime_stats' and column_name in ('city_insee_code','year','category_id','incident_count','rate_per_1000','publication_status','source','imported_at','import_batch_id');" `
        -Expected "9" `
        -Message "crime_stats does not expose the expected annual statistic fields"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_constraint where conname in ('crime_stats_city_year_category_source_key','population_history_city_year_source_key');" `
        -Expected "2" `
        -Message "Idempotent import uniqueness constraints are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_indexes where indexname in ('search_metrics_category_lookup_idx','search_metrics_comparative_year_lookup_idx');" `
        -Expected "2" `
        -Message "Snapshot lookup indexes are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.tables where table_schema = 'public' and table_name similar to '%(score|color|rank|percentile|risk)%';" `
        -Expected "0" `
        -Message "Derived scoring/color/ranking tables should not live with raw official data"

    Write-Host "Database schema test passed."
}
finally {
    docker rm -f $ContainerName 2>$null | Out-Null
}
