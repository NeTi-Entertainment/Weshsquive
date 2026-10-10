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
        -Sql "select count(*) from information_schema.columns where table_name = 'city_year_comparative_components' and column_name in ('city_insee_code','year','category_code','population_band','component_source','effective_rate_per_1000','reference_cohort_size','category_percentile');" `
        -Expected "8" `
        -Message "The comparative component view does not expose its audit contract"

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.columns where table_name = 'city_year_comparative_metrics' and column_name in ('estimated_basket_category_count','comparable_basket_category_count','estimated_availability_mask','minimum_reference_cohort_size','comparative_index_provenance','comparative_index_status','comparative_index','basket_version');" `
        -Expected "8" `
        -Message "The comparative metrics view does not expose all v2 fields"

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
        -Sql "select string_agg(reference_population || ':' || population_band, ',' order by reference_population) from cities join city_year_comparative_metrics on city_insee_code=insee_code and year=2025 where source is null and insee_code like 'B%';" `
        -Expected "999:under-1000,1000:1000-4999,4999:1000-4999,5000:5000-9999,9999:5000-9999,10000:10000-49999,49999:10000-49999,50000:50000-plus,100000:50000-plus" `
        -Message "Comparative metrics must use the five v2 population bands at every boundary"

    Assert-SqlEquals `
        -Sql "select count(distinct basket_version) || ':' || min(basket_version) from city_year_comparative_metrics where year=2025;" `
        -Expected "1:residential-risk-v2" `
        -Message "Comparative metrics must expose only the v2 basket version"

    Write-Host "Database schema test passed."
}
finally {
    docker rm -f $ContainerName 2>$null | Out-Null
}
