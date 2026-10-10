param(
    [string]$DatabaseName = "app_criminalite_test",
    [string]$ContainerName = "app-criminalite-schema-test"
)

$ErrorActionPreference = "Stop"

$ContainerName = "$ContainerName-$PID"
$UpgradeDatabaseName = "${DatabaseName}_upgrade"

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
        [string]$Message,
        [string]$TargetDatabase = $DatabaseName
    )

    $actual = (Invoke-Psql -Sql $Sql -TargetDatabase $TargetDatabase -TuplesOnly).Trim()
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

    & (Join-Path $PSScriptRoot "apply_migrations.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    if ($LASTEXITCODE -ne 0) {
        throw "Fresh database migration run failed."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from schema_migrations where migration_name = '006_comparative_index_v2.sql';" `
        -Expected "1" `
        -Message "The ordered migration runner did not register migration 006 on a fresh database"

    Assert-SqlEquals `
        -Sql "select count(*) from schema_migrations where migration_name = '007_city_boundaries.sql';" `
        -Expected "1" `
        -Message "The ordered migration runner did not register migration 007 on a fresh database"

    Assert-SqlEquals `
        -Sql "select count(*) from schema_migrations where migration_name = '008_absolute_exposure_index.sql';" `
        -Expected "1" `
        -Message "The ordered migration runner did not register migration 008 on a fresh database"

    docker exec -e PGPASSWORD=postgres $ContainerName `
        createdb -U postgres $UpgradeDatabaseName

    $upgradeMigrations = $migrationFiles | Where-Object Name -Match '^00[1-5]_'
    foreach ($migration in $upgradeMigrations) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)"
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $UpgradeDatabaseName -f "/tmp/$($migration.Name)" `
            | Out-Null
    }

    Invoke-Psql `
        -TargetDatabase $UpgradeDatabaseName `
        -Sql "create table schema_migrations (migration_name text primary key, applied_at timestamptz not null default now()); insert into schema_migrations(migration_name) values ('001_initial_postgis_schema.sql'),('002_comparative_index_views.sql'),('003_ssmsi_units_and_denominators.sql'),('004_search_metric_snapshots.sql'),('005_property_market_layers.sql');" `
        | Out-Null

    & (Join-Path $PSScriptRoot "apply_migrations.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $UpgradeDatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    if ($LASTEXITCODE -ne 0) {
        throw "Upgraded database migration run failed."
    }

    Assert-SqlEquals `
        -TargetDatabase $UpgradeDatabaseName `
        -Sql "select count(*) from schema_migrations where migration_name = '006_comparative_index_v2.sql';" `
        -Expected "1" `
        -Message "The ordered migration runner did not register migration 006 on an upgraded database"

    Assert-SqlEquals `
        -TargetDatabase $UpgradeDatabaseName `
        -Sql "select count(*) from schema_migrations where migration_name = '007_city_boundaries.sql';" `
        -Expected "1" `
        -Message "The ordered migration runner did not register migration 007 on an upgraded database"

    Assert-SqlEquals `
        -TargetDatabase $UpgradeDatabaseName `
        -Sql "select count(*) from schema_migrations where migration_name = '008_absolute_exposure_index.sql';" `
        -Expected "1" `
        -Message "The ordered migration runner did not register migration 008 on an upgraded database"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_extension where extname in ('postgis','postgis_topology');" `
        -Expected "2" `
        -Message "PostGIS extensions are not installed"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.tables where table_schema = 'public' and table_name in ('regions','departments','cities','crime_categories','crime_stats','population_history','import_batches','search_metric_snapshots','search_metrics_active','search_metrics_city_year_category','search_metrics_city_year_comparative','property_sale_observations','property_rent_observations','property_market_metrics','exposure_index_category_anchors');" `
        -Expected "15" `
        -Message "Core and derived search metric tables are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name='search_metrics_city_year_comparative' and column_name='comparative_index' and data_type='numeric' and numeric_precision=5 and numeric_scale=1;" `
        -Expected "1" `
        -Message "The comparative snapshot must retain one decimal place for the exposure index"

    Assert-SqlEquals `
        -Sql "select count(*) from exposure_index_category_anchors where calibration_year=2025;" `
        -Expected "6" `
        -Message "All six fixed exposure calibrations must be installed"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_constraint where conname in ('property_sale_observations_pkey','property_rent_observations_pkey','property_market_metrics_pkey','property_market_metric_type_check','property_market_publication_check');" `
        -Expected "5" `
        -Message "Property market idempotence and publication constraints are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_indexes where indexname in ('property_sale_city_year_type_idx','property_rent_city_year_type_idx','property_market_lookup_idx');" `
        -Expected "3" `
        -Message "Property market lookup indexes are missing"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name = 'cities' and column_name in ('insee_code','name','department_code','region_code','latitude','longitude','geom','boundary_geom','reference_population','population_year');" `
        -Expected "10" `
        -Message "cities does not expose the expected stable commune fields"

    Assert-SqlEquals `
        -Sql "select count(*) from geometry_columns where f_table_schema='public' and f_table_name='cities' and f_geometry_column='boundary_geom' and type='MULTIPOLYGON' and srid=4326;" `
        -Expected "1" `
        -Message "The city boundary column must contain WGS84 MultiPolygons"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_indexes where tablename='cities' and indexname='cities_boundary_geom_gix' and indexdef ilike '%using gist (boundary_geom)%';" `
        -Expected "1" `
        -Message "The city boundary geometry needs a GiST index"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name = 'crime_stats' and column_name in ('city_insee_code','year','category_id','incident_count','rate_per_1000','publication_status','source','imported_at','import_batch_id','count_unit','insee_pop','insee_pop_millesime','insee_log','insee_log_millesime','complement_info_nombre','complement_info_taux','rate_denominator');" `
        -Expected "17" `
        -Message "crime_stats does not expose the expected annual statistic fields"

    Assert-SqlEquals `
        -Sql "select count(*) from pg_constraint where conrelid = 'crime_stats'::regclass and conname in ('crime_stats_incident_count_check','crime_stats_rate_per_1000_check','crime_stats_masked_values_are_null_check','crime_stats_city_year_category_source_key');" `
        -Expected "4" `
        -Message "Migration 006 must preserve raw crime_stats integrity constraints"

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

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.views where table_schema = 'public' and table_name = 'city_year_comparative_components';" `
        -Expected "1" `
        -Message "The auditable comparative component view is missing"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name = 'city_year_comparative_components' and column_name in ('city_insee_code','year','category_code','availability_bit','anchored_rate_denominator','anchored_count_unit','anchor_rate_per_1000','component_source','effective_rate_per_1000','component_exposure_score');" `
        -Expected "10" `
        -Message "The absolute exposure component view does not expose its audit contract"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name = 'city_year_comparative_metrics' and column_name in ('published_basket_category_count','estimated_basket_category_count','effective_basket_category_count','basket_index_coverage','low_volume_cap_applied','estimated_availability_mask','comparative_index_provenance','comparative_index_status','comparative_index','basket_version');" `
        -Expected "10" `
        -Message "The comparative metrics view does not expose the absolute exposure contract"

    Invoke-Psql -Sql @"
insert into regions(code, name) values ('11', 'Ile-de-France');
insert into departments(code, name, region_code) values ('75', 'Paris', '11');
insert into cities(insee_code, name, department_code, region_code, reference_population, population_year) values
('B0999', 'Boundary 999', '75', '11', 999, 2025),
('B1000', 'Boundary 1000', '75', '11', 1000, 2025),
('B4999', 'Boundary 4999', '75', '11', 4999, 2025),
('B5000', 'Boundary 5000', '75', '11', 5000, 2025),
('B9999', 'Boundary 9999', '75', '11', 9999, 2025),
('B10K0', 'Boundary 10000', '75', '11', 10000, 2025),
('B49K9', 'Boundary 49999', '75', '11', 49999, 2025),
('B50K0', 'Boundary 50000', '75', '11', 50000, 2025),
('B100K', 'Boundary 100000', '75', '11', 100000, 2025);
insert into crime_categories(code, label, source) values ('schema-year', 'Schema year fixture', 'fixture');
insert into crime_stats(city_insee_code, year, category_id, publication_status, source)
select 'B0999', 2025, id, 'unknown', 'fixture' from crime_categories where code = 'schema-year';
"@ | Out-Null

    Assert-SqlEquals `
        -Sql "select count(*) from city_year_comparative_metrics where city_insee_code like 'B%' and year=2025;" `
        -Expected "9" `
        -Message "Absolute exposure metrics must not require a population cohort"

    Assert-SqlEquals `
        -Sql "select count(distinct basket_version) || ':' || min(basket_version) from city_year_comparative_metrics where year=2025;" `
        -Expected "1:absolute-exposure-v1" `
        -Message "Comparative metrics must expose the fixed absolute exposure formula version"

    Write-Host "Database schema test passed."
}
finally {
    docker rm -f $ContainerName 2>$null | Out-Null
}
