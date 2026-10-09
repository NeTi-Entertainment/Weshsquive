param(
    [string]$DatabaseName = "app_criminalite_property_metrics_test",
    [string]$ContainerName = "app-criminalite-property-metrics-test"
)

$ErrorActionPreference = "Stop"
$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"

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
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $Sql" }
    return $output
}

function Assert-SqlEquals {
    param([string]$Sql, [string]$Expected, [string]$Message)
    $actual = (Invoke-Psql -Sql $Sql -TuplesOnly).Trim()
    if ($actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$actual'."
    }
}

docker rm -f $ContainerName 2>$null | Out-Null

try {
    docker run --name $ContainerName -e POSTGRES_PASSWORD=postgres -d postgis/postgis:16-3.4 | Out-Null

    $initComplete = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
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
    if (-not $initComplete) { throw "PostgreSQL initialization did not complete." }

    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        docker exec -e PGPASSWORD=postgres $ContainerName pg_isready -U postgres -d postgres *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "PostgreSQL did not become ready." }

    docker exec -e PGPASSWORD=postgres $ContainerName createdb -U postgres $DatabaseName
    foreach ($migration in (Get-ChildItem $migrationDir -Filter "*.sql" -File | Sort-Object Name)) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)" | Out-Null
        docker exec -e PGPASSWORD=postgres $ContainerName psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($migration.Name)" }
    }

    Invoke-Psql -Sql @'
insert into regions(code, name) values ('75', 'Nouvelle-Aquitaine'), ('44', 'Grand Est'), ('06', 'Mayotte');
insert into departments(code, name, region_code) values
('33', 'Gironde', '75'), ('57', 'Moselle', '44'), ('67', 'Bas-Rhin', '44'),
('68', 'Haut-Rhin', '44'), ('976', 'Mayotte', '06');
insert into cities(insee_code, name, department_code, region_code) values
('33001', 'Alpha', '33', '75'), ('33002', 'Beta', '33', '75'),
('33003', 'Gamma', '33', '75'), ('33004', 'Delta', '33', '75'),
('33005', 'Epsilon', '33', '75'), ('57001', 'Moselle Ville', '57', '44'),
('67001', 'Alsace Nord', '67', '44'), ('68001', 'Alsace Sud', '68', '44'),
('97601', 'Mayotte Ville', '976', '06');

insert into import_batches(source_system, source_year, status, metadata, completed_at)
values ('dvf-geolocated', 2025, 'completed', '{}'::jsonb, now()),
       ('anil-rent-map', 2025, 'completed', '{}'::jsonb, now());

insert into property_sale_observations(
  source_system, source_year, mutation_id, city_insee_code, mutation_date,
  mutation_nature, property_type, sale_value, built_area, import_batch_id
)
select 'dvf-geolocated', 2025, 'A' || n, '33001', date '2025-01-01' + n,
       'Vente', 'apartment', n * 100000, 100,
       (select id from import_batches where source_system = 'dvf-geolocated')
from generate_series(1, 5) n;

insert into property_sale_observations(
  source_system, source_year, mutation_id, city_insee_code, mutation_date,
  mutation_nature, property_type, sale_value, built_area, import_batch_id
)
values
('dvf-geolocated', 2025, 'A-outlier', '33001', '2025-02-01', 'Vente', 'apartment', 200000, 1,
 (select id from import_batches where source_system = 'dvf-geolocated'));

insert into property_sale_observations(
  source_system, source_year, mutation_id, city_insee_code, mutation_date,
  mutation_nature, property_type, sale_value, built_area, import_batch_id
)
select 'dvf-geolocated', 2025, 'B' || n, '33002', date '2025-03-01' + n,
       'Vente', 'apartment', n * 90000, 100,
       (select id from import_batches where source_system = 'dvf-geolocated')
from generate_series(1, 4) n;

insert into property_sale_observations(
  source_system, source_year, mutation_id, city_insee_code, mutation_date,
  mutation_nature, property_type, sale_value, built_area, import_batch_id
)
select 'dvf-geolocated', 2025, 'D' || n, '33004', date '2025-04-01' + n,
       'Vente', 'apartment', (n + 5) * 100000, 100,
       (select id from import_batches where source_system = 'dvf-geolocated')
from generate_series(1, 5) n;

insert into property_sale_observations(
  source_system, source_year, mutation_id, city_insee_code, mutation_date,
  mutation_nature, property_type, sale_value, built_area, import_batch_id
)
select 'dvf-geolocated', 2025, 'AH' || n, '33001', date '2025-05-01' + n,
       'Vente', 'house', (n + 2) * 100000, 100,
       (select id from import_batches where source_system = 'dvf-geolocated')
from generate_series(1, 5) n;

insert into property_sale_observations(
  source_system, source_year, mutation_id, city_insee_code, mutation_date,
  mutation_nature, property_type, sale_value, built_area, import_batch_id
)
select 'dvf-geolocated', 2025, 'M' || n, '57001', date '2025-06-01' + n,
       'Vente', 'house', n * 100000, 100,
       (select id from import_batches where source_system = 'dvf-geolocated')
from generate_series(1, 5) n;

insert into property_rent_observations(
  source_system, source_year, city_insee_code, property_type,
  estimated_rent_per_m2, lower_bound_per_m2, upper_bound_per_m2,
  prediction_type, commune_observation_count, grid_observation_count,
  adjusted_r2, import_batch_id
)
values
('anil-rent-map', 2025, '33001', 'apartment', 12, 10, 14, 'commune', 30, 40, 0.5,
 (select id from import_batches where source_system = 'anil-rent-map')),
('anil-rent-map', 2025, '33001', 'house', 15, 13, 17, 'commune', 29, 40, 0.8,
 (select id from import_batches where source_system = 'anil-rent-map')),
('anil-rent-map', 2025, '33002', 'apartment', 14, 12, 16, 'grid', 100, 120, 0.8,
 (select id from import_batches where source_system = 'anil-rent-map')),
('anil-rent-map', 2025, '33004', 'apartment', 18, 16, 20, 'commune', 40, 50, 0.8,
 (select id from import_batches where source_system = 'anil-rent-map')),
('anil-rent-map', 2025, '33005', 'apartment', 12, 15, 14, 'commune', 40, 50, 0.8,
 (select id from import_batches where source_system = 'anil-rent-map')),
('anil-rent-map', 2025, '97601', 'house', 20, 18, 22, 'commune', 50, 60, 0.9,
 (select id from import_batches where source_system = 'anil-rent-map'));

select refresh_property_market_metrics(2025::smallint);
'@ | Out-Null

    Assert-SqlEquals -Sql "select count(*) from property_market_metrics where year = 2025;" -Expected "45" -Message "Five market metrics should exist for every commune"
    Assert-SqlEquals -Sql "select value_per_m2::integer || '|' || sample_count from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='sale' and property_type='apartment';" -Expected "3000|5" -Message "DVF median should exclude the retained extreme value"
    Assert-SqlEquals -Sql "select value_per_m2::integer || '|' || sample_count from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='sale' and property_type='all';" -Expected "4000|10" -Message "All-home median should use eligible mutations, not type medians"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33002' and year=2025 and metric_kind='sale' and property_type='apartment';" -Expected "insufficient-sample" -Message "Four sales should remain unpublished"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33003' and year=2025 and metric_kind='sale' and property_type='apartment';" -Expected "no-data" -Message "A covered city without a sale should be no-data"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='57001' and year=2025 and metric_kind='sale' and property_type='house';" -Expected "source-uncovered" -Message "Moselle should be outside DVF coverage"
    Assert-SqlEquals -Sql "select count(*) from property_market_metrics where year=2025 and metric_kind='sale' and display_status='source-uncovered' and city_insee_code in ('57001','67001','68001','97601');" -Expected "12" -Message "Every sale variant should mark all four uncovered departments"
    Assert-SqlEquals -Sql "select national_percentile::text from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='sale' and property_type='apartment';" -Expected "0.0000000000" -Message "Published sale percentiles should use comparable published cities"
    Assert-SqlEquals -Sql "select national_percentile::text from property_market_metrics where city_insee_code='33004' and year=2025 and metric_kind='sale' and property_type='apartment';" -Expected "1.0000000000" -Message "Highest published sale median should have percentile one"
    Assert-SqlEquals -Sql "select value_per_m2::integer || '|' || sample_count || '|' || national_percentile::text from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='rent' and property_type='apartment';" -Expected "12|30|0.0000000000" -Message "ANIL boundary quality values should be publishable"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='rent' and property_type='house';" -Expected "insufficient-quality" -Message "A rent estimate below 30 observations should be gray"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33002' and year=2025 and metric_kind='rent' and property_type='apartment';" -Expected "non-communal-estimate" -Message "A grid estimate should not be published as communal"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33005' and year=2025 and metric_kind='rent' and property_type='apartment';" -Expected "invalid-value" -Message "An incoherent interval should be gray"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='97601' and year=2025 and metric_kind='rent' and property_type='house';" -Expected "source-uncovered" -Message "Mayotte should be outside ANIL coverage"

    Write-Host "Property market metrics test passed."
}
finally {
    docker rm -f $ContainerName 2>$null | Out-Null
}
