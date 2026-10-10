param(
    [string]$DatabaseName = "app_criminalite_comparative_v2_test",
    [string]$ContainerName = "app-criminalite-comparative-v2-test"
)

$ErrorActionPreference = "Stop"
$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$refreshScript = Join-Path $PSScriptRoot "refresh_search_metrics.ps1"

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

    $actual = (Invoke-Psql -Sql $Sql -TuplesOnly).Trim() -replace "\r\n?", "`n"
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

    $baselineMigrations = Get-ChildItem $migrationDir -Filter "*.sql" -File |
        Where-Object Name -Match '^00[1-5]_' |
        Sort-Object Name
    foreach ($migration in $baselineMigrations) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)" | Out-Null
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($migration.Name)" }
    }

    Invoke-Psql -Sql @'
insert into regions(code, name) values ('11', 'Ile-de-France');
insert into departments(code, name, region_code) values ('75', 'Paris', '11');

insert into cities(insee_code, name, department_code, region_code, reference_population, population_year)
select 'R' || lpad(n::text, 4, '0'), 'Reference ' || n, '75', '11', 2000, 2025
from generate_series(1, 50) n;

insert into cities(insee_code, name, department_code, region_code, reference_population, population_year) values
('P0001', 'Published only', '75', '11', 2000, 2025),
('Q0001', 'Partially estimated', '75', '11', 2000, 2025),
('E0001', 'Estimated only', '75', '11', 2000, 2025),
('X0001', 'Mixed reference cohorts', '75', '11', 2000, 2025),
('U0001', 'Unknown values', '75', '11', 2000, 2025),
('I0001', 'Insufficient coverage', '75', '11', 2000, 2025),
('M0001', 'Missing population', '75', '11', null, null),
('S0001', 'Small reference cohort', '75', '11', 500, 2025),
('C0001', 'Contradictory denominator', '75', '11', 2000, 2025),
('H5001', 'Fifty thousand', '75', '11', 50000, 2025),
('H1001', 'One hundred thousand', '75', '11', 100000, 2025);

insert into crime_categories(code, label, source) values
('ssmsi-78384436563146dc6167ea53b7b5e0cd', 'Cambriolages de logement', 'fixture'),
('ssmsi-74a195792dd119f60822e61df3587522', 'Vols de véhicule', 'fixture'),
('ssmsi-d3e9d2e40d72b8850d5283eb73bdc928', 'Vols dans les véhicules', 'fixture'),
('ssmsi-bf6b19b3e53b90f6594ec2e8303c5778', 'Destructions et dégradations volontaires', 'fixture'),
('ssmsi-a2601b900aa009440624697e1d74e4a9', 'Violences physiques hors cadre familial', 'fixture'),
('ssmsi-bdbeb8ca73503f8264dab16159795328', 'Trafic de stupéfiants', 'fixture');

with reference_rates as (
    select
        n,
        case when n = 50 then 10 else n end::numeric as rate
    from generate_series(1, 50) n
)
insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, rate_denominator
)
select
    'R' || lpad(reference_rates.n::text, 4, '0'),
    2025,
    category.id,
    case
        when category.label = 'Cambriolages de logement' then reference_rates.rate::integer
        else (reference_rates.rate * 2)::integer
    end,
    reference_rates.rate,
    'published',
    'fixture',
    'Infraction',
    2000,
    2025,
    1000,
    2025,
    case
        when reference_rates.n = 1 and category.label = 'Cambriolages de logement' then 'housing'
        else 'unknown'
    end
from reference_rates
cross join crime_categories category;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, complement_info_nombre,
    complement_info_taux, rate_denominator
)
select 'P0001', 2025, id,
       case row_number() over (order by id) when 1 then 10 when 2 then 40 else 60 end,
       case row_number() over (order by id) when 1 then 10 when 2 then 20 else 30 end,
       'published', 'fixture', 'Infraction', 2000, 2025, 1000, 2025, null, null, 'unknown'
from crime_categories
order by id
limit 3;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, complement_info_nombre,
    complement_info_taux, rate_denominator
)
select 'X0001', 2025, id, null, null, 'masked', 'fixture', 'Infraction', 2000, 2025, 1000, 2025,
       666, case row_number() over (order by id) when 1 then 12 when 2 then 22 else 32 end, 'unknown'
from crime_categories
order by id
limit 3;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, rate_denominator
)
select 'X0001', 2025, id, 20, 10, 'published', 'fixture', 'Victime',
       2000, 2025, 1000, 2025, 'unknown'
from crime_categories
order by id
offset 3
limit 1;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, complement_info_nombre,
    complement_info_taux, rate_denominator
)
select 'Q0001', 2025, id,
       case row_number() over (order by id) when 1 then 0 when 3 then 80 else null end,
       case row_number() over (order by id) when 1 then 0 when 3 then 40 else null end,
       case row_number() over (order by id) when 2 then 'masked'::publication_status else 'published'::publication_status end,
       'fixture', 'Infraction', 2000, 2025, 1000, 2025,
       case row_number() over (order by id) when 2 then 999 else null end,
       case row_number() over (order by id) when 2 then 25 else null end,
       'unknown'
from crime_categories
order by id
limit 3;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, complement_info_nombre,
    complement_info_taux, rate_denominator
)
select 'E0001', 2025, id, null, null, 'masked', 'fixture', 'Infraction', 2000, 2025, 1000, 2025,
       777, case row_number() over (order by id) when 1 then 100 when 2 then 25 else 35 end, 'unknown'
from crime_categories
order by id
limit 3;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, complement_info_nombre,
    complement_info_taux, rate_denominator
)
select 'U0001', 2025, id, null, null, 'unknown', 'fixture', 'Infraction', 2000, 2025, 1000, 2025,
       888, 80, 'unknown'
from crime_categories
order by id
limit 3;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, rate_denominator
)
select 'I0001', 2025, id,
       case row_number() over (order by id) when 1 then 5 else 30 end,
       case row_number() over (order by id) when 1 then 5 else 15 end,
       'published', 'fixture', 'Infraction', 2000, 2025, 1000, 2025, 'unknown'
from crime_categories
order by id
limit 2;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, rate_denominator
)
select 'M0001', 2025, id,
       case row_number() over (order by id) when 1 then 10 when 2 then 40 else 60 end,
       case row_number() over (order by id) when 1 then 10 when 2 then 20 else 30 end,
       'published', 'fixture', 'Infraction', 2000, 2025, 1000, 2025, 'unknown'
from crime_categories
order by id
limit 3;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, rate_denominator
)
select 'S0001', 2025, id,
       case row_number() over (order by id) when 1 then 1 else 5 end,
       case row_number() over (order by id) when 1 then 4 else 10 end,
       'published', 'fixture', 'Infraction', 500, 2025, 250, 2025, 'unknown'
from crime_categories
order by id
limit 3;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, rate_denominator
)
select 'C0001', 2025, id, 1, 999, 'published', 'fixture', 'Infraction',
       2000, 2025, 1000, 2025, 'unknown'
from crime_categories
order by id
limit 1;
'@ | Out-Null

    $officialValuesBefore = (Invoke-Psql -Sql @'
select md5(string_agg(
    jsonb_build_array(
        city_insee_code,
        year,
        category_id,
        incident_count,
        rate_per_1000,
        publication_status::text,
        source,
        import_batch_id,
        imported_at,
        count_unit,
        insee_pop,
        insee_pop_millesime,
        insee_log,
        insee_log_millesime,
        complement_info_nombre,
        complement_info_taux
    )::text,
    E'\n' order by id
))
from crime_stats;
'@ -TuplesOnly).Trim()

    $preclassifiedXmin = (Invoke-Psql `
        -Sql "select statistic.xmin::text from crime_stats statistic join crime_categories category on category.id=statistic.category_id where statistic.city_insee_code='R0001' and category.label='Cambriolages de logement';" `
        -TuplesOnly).Trim()

    $v2Migration = Get-Item (Join-Path $migrationDir "006_comparative_index_v2.sql") -ErrorAction SilentlyContinue
    if ($null -ne $v2Migration) {
        docker cp $v2Migration.FullName "${ContainerName}:/tmp/$($v2Migration.Name)" | Out-Null
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($v2Migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($v2Migration.Name)" }
    }

    Assert-SqlEquals `
        -Sql "select count(*) from information_schema.views where table_schema='public' and table_name='city_year_comparative_components';" `
        -Expected "1" `
        -Message "The auditable comparative component view is missing"

    Assert-SqlEquals `
        -Sql @'
select md5(string_agg(
    jsonb_build_array(
        city_insee_code,
        year,
        category_id,
        incident_count,
        rate_per_1000,
        publication_status::text,
        source,
        import_batch_id,
        imported_at,
        count_unit,
        insee_pop,
        insee_pop_millesime,
        insee_log,
        insee_log_millesime,
        complement_info_nombre,
        complement_info_taux
    )::text,
    E'\n' order by id
))
from crime_stats;
'@ `
        -Expected $officialValuesBefore `
        -Message "Migration 006 must preserve every official crime_stats value for every fixture"

    Assert-SqlEquals `
        -Sql "select statistic.xmin::text from crime_stats statistic join crime_categories category on category.id=statistic.category_id where statistic.city_insee_code='R0001' and category.label='Cambriolages de logement';" `
        -Expected $preclassifiedXmin `
        -Message "Migration 006 must not rewrite rows whose derived denominator is already correct"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats where publication_status='masked' and (incident_count is not null or rate_per_1000 is not null);" `
        -Expected "0" `
        -Message "Masked communal values must remain null"

    Assert-SqlEquals `
        -Sql "select component_source || '|' || trim(to_char(effective_rate_per_1000, 'FM999990.0000')) from city_year_comparative_components where city_insee_code='Q0001' and year=2025 and category_code='ssmsi-74a195792dd119f60822e61df3587522';" `
        -Expected "department-masked-average|25.0000" `
        -Message "Only complement_info_taux should supply a masked component"

    Assert-SqlEquals `
        -Sql "select (component_source is null)::text || '|' || (effective_rate_per_1000 is null)::text from city_year_comparative_components where city_insee_code='U0001' and year=2025 and category_code='ssmsi-78384436563146dc6167ea53b7b5e0cd';" `
        -Expected "true|true" `
        -Message "Unknown rows must never use their complements"

    Assert-SqlEquals `
        -Sql "select component_source || '|' || effective_rate_per_1000::integer from city_year_comparative_components where city_insee_code='Q0001' and year=2025 and category_code='ssmsi-78384436563146dc6167ea53b7b5e0cd';" `
        -Expected "published|0" `
        -Message "A published zero must take precedence over complements"

    Assert-SqlEquals `
        -Sql "select reference_cohort_size || '|' || round(category_percentile, 4) from city_year_comparative_components where city_insee_code='Q0001' and year=2025 and category_code='ssmsi-74a195792dd119f60822e61df3587522';" `
        -Expected "52|0.5294" `
        -Message "Reference cohorts must contain published rows only"

    Assert-SqlEquals `
        -Sql "select reference_cohort_size || '|' || round(category_percentile, 4) from city_year_comparative_components where city_insee_code='P0001' and year=2025 and category_code='ssmsi-78384436563146dc6167ea53b7b5e0cd';" `
        -Expected "53|0.2115" `
        -Message "Tied values must use strict-less percent_rank semantics"

    Assert-SqlEquals `
        -Sql "select category_percentile::integer from city_year_comparative_components where city_insee_code='E0001' and year=2025 and category_code='ssmsi-78384436563146dc6167ea53b7b5e0cd';" `
        -Expected "1" `
        -Message "Out-of-range fallback percentiles must be bounded to one"

    Assert-SqlEquals `
        -Sql "select string_agg(population_band, ',' order by city_insee_code) from city_year_comparative_metrics where city_insee_code in ('H5001','H1001') and year=2025;" `
        -Expected "50000-plus,50000-plus" `
        -Message "Both former upper bands must resolve to 50000-plus"

    Assert-SqlEquals `
        -Sql "select minimum_reference_cohort_size || '|' || comparative_index_status || '|' || comparable_basket_category_count from city_year_comparative_metrics where city_insee_code='X0001' and year=2025;" `
        -Expected "52|comparable|3" `
        -Message "The minimum reference cohort must include only components retained in the comparative index"

    Assert-SqlEquals `
        -Sql "select availability_mask || '|' || estimated_availability_mask || '|' || comparative_index_status from city_year_comparative_metrics where city_insee_code='P0001' and year=2025;" `
        -Expected "7|0|comparable" `
        -Message "Exact availability masks must not split reference cohorts"

    Assert-SqlEquals `
        -Sql "select comparative_index || '|' || comparative_index_provenance || '|' || published_basket_category_count || '|' || estimated_basket_category_count || '|' || comparable_basket_category_count from city_year_comparative_metrics where city_insee_code='Q0001' and year=2025;" `
        -Expected "44|partially-estimated|2|1|3" `
        -Message "The final score must be the rounded equal-weight mean with explicit provenance"

    Assert-SqlEquals `
        -Sql "select comparative_index || '|' || comparative_index_provenance from city_year_comparative_metrics where city_insee_code='E0001' and year=2025;" `
        -Expected "75|estimated-only" `
        -Message "An estimated-only index should remain comparable"

    Assert-SqlEquals `
        -Sql "select count(distinct comparative_index_provenance) from city_year_comparative_metrics where year=2025;" `
        -Expected "4" `
        -Message "All four comparative-index provenance values must be reachable"

    Assert-SqlEquals `
        -Sql "select count(distinct comparative_index_status) from city_year_comparative_metrics where year=2025;" `
        -Expected "4" `
        -Message "All four comparative-index availability statuses must be reachable"

    Assert-SqlEquals `
        -Sql "select comparative_index_status || '|' || comparative_index_provenance from city_year_comparative_metrics where city_insee_code='U0001' and year=2025;" `
        -Expected "insufficient-coverage|unavailable" `
        -Message "Unknown-only data should remain unavailable"

    Assert-SqlEquals `
        -Sql "select comparative_index_status from city_year_comparative_metrics where city_insee_code='M0001' and year=2025;" `
        -Expected "population-unavailable" `
        -Message "A missing population must prevent comparison"

    Assert-SqlEquals `
        -Sql "select comparative_index_status from city_year_comparative_metrics where city_insee_code='S0001' and year=2025;" `
        -Expected "reference-cohort-too-small" `
        -Message "Three effective components with small references must report the cohort status"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_categories where code like 'ssmsi-%' and rate_denominator_reference in ('population','housing');" `
        -Expected "6" `
        -Message "Official basket categories must receive documented denominators"

    Assert-SqlEquals `
        -Sql "select rate_per_1000::integer || '|' || incident_count || '|' || rate_denominator from crime_stats where city_insee_code='C0001' and year=2025;" `
        -Expected "999|1|unknown" `
        -Message "Contradictory official values must remain intact and keep an unknown denominator"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats where publication_status='masked' and rate_denominator in ('population','housing');" `
        -Expected "7" `
        -Message "Masked rows may inherit a documented denominator without changing raw values"

    Assert-SqlEquals `
        -Sql "select basket_version from city_year_comparative_metrics where city_insee_code='P0001' and year=2025;" `
        -Expected "residential-risk-v2" `
        -Message "The v2 formula must identify its basket version"

    Invoke-Psql -Sql @'
insert into cities(insee_code, name, department_code, region_code, reference_population, population_year) values
('V3P01', 'Exposure guardrail', '75', '11', 100000, 2025),
('V3P02', 'Same rate larger city', '75', '11', 500000, 2025);

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, complement_info_taux, rate_denominator
)
select 'V3P01', 2025, category.id, fixture.incident_count, fixture.rate_per_1000,
       fixture.publication_status::publication_status, 'fixture', fixture.count_unit,
       100000, 2025, 1000, 2025, fixture.complement_rate, fixture.rate_denominator
from (values
    ('ssmsi-78384436563146dc6167ea53b7b5e0cd', 4, 4::numeric, 'published', 'Infraction', 'housing', null::numeric),
    ('ssmsi-74a195792dd119f60822e61df3587522', 520, 5.1964::numeric, 'published', 'Véhicule', 'population', null::numeric),
    ('ssmsi-d3e9d2e40d72b8850d5283eb73bdc928', 1325, 13.2453::numeric, 'published', 'Véhicule', 'population', null::numeric),
    ('ssmsi-bf6b19b3e53b90f6594ec2e8303c5778', 3, 0.03::numeric, 'published', 'Infraction', 'population', null::numeric),
    ('ssmsi-a2601b900aa009440624697e1d74e4a9', null::integer, null::numeric, 'masked', 'Victime', 'population', 8.5257::numeric),
    ('ssmsi-bdbeb8ca73503f8264dab16159795328', 518, 5.1832::numeric, 'published', 'Mis en cause', 'population', null::numeric)
) as fixture(category_code, incident_count, rate_per_1000, publication_status, count_unit, rate_denominator, complement_rate)
join crime_categories category on category.code = fixture.category_code;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, insee_pop, insee_pop_millesime,
    insee_log, insee_log_millesime, rate_denominator
)
select 'V3P02', 2025, category.id, 200, 4, 'published', 'fixture', 'Infraction',
       500000, 2025, 50000, 2025, 'housing'
from crime_categories category
where category.code = 'ssmsi-78384436563146dc6167ea53b7b5e0cd';
'@ | Out-Null

    $rawValuesBeforeExposureMigration = (Invoke-Psql -Sql @'
select md5(string_agg(
    jsonb_build_array(city_insee_code, year, category_id, incident_count, rate_per_1000,
        publication_status::text, source, count_unit, insee_pop, insee_pop_millesime,
        insee_log, insee_log_millesime, complement_info_nombre, complement_info_taux,
        rate_denominator)::text,
    E'\n' order by id
)) from crime_stats;
'@ -TuplesOnly).Trim()

    $exposureMigration = Get-Item (Join-Path $migrationDir "008_absolute_exposure_index.sql")
    docker cp $exposureMigration.FullName "${ContainerName}:/tmp/$($exposureMigration.Name)" | Out-Null
    docker exec -e PGPASSWORD=postgres $ContainerName `
        psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($exposureMigration.Name)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($exposureMigration.Name)" }

    Assert-SqlEquals `
        -Sql "select count(*) from exposure_index_category_anchors where calibration_year=2025;" `
        -Expected "6" `
        -Message "The fixed 2025 exposure calibration must cover all six basket categories"

    Assert-SqlEquals `
        -Sql "select round(max(component_exposure_score), 4) || '|' || round(min(component_exposure_score), 4) from city_year_comparative_components where category_code='ssmsi-78384436563146dc6167ea53b7b5e0cd' and city_insee_code in ('V3P01','V3P02');" `
        -Expected "24.9268|24.9268" `
        -Message "An identical published rate must have the same risk score across population sizes"

    Assert-SqlEquals `
        -Sql "select comparative_index || '|' || comparative_index_provenance || '|' || published_basket_category_count || '|' || estimated_basket_category_count || '|' || low_volume_cap_applied from city_year_comparative_metrics where city_insee_code='V3P01' and year=2025;" `
        -Expected "35|partially-estimated|5|1|true" `
        -Message "The guardrail must cap an otherwise high score using the two published Infraction counts only"

    Assert-SqlEquals `
        -Sql "select component.component_source || '|' || round(component.component_exposure_score, 1) || '|' || (metrics.rate_per_1000 is null)::text from city_year_comparative_components component join city_year_category_metrics metrics using (city_insee_code, year, category_code) where component.city_insee_code='V3P01' and component.category_code='ssmsi-a2601b900aa009440624697e1d74e4a9';" `
        -Expected "department-masked-average|100.0|true" `
        -Message "A department complement may score a masked component without publishing a communal rate"

    Assert-SqlEquals `
        -Sql "select comparative_index || '|' || low_volume_cap_applied from city_year_comparative_metrics where city_insee_code='V3P02' and year=2025;" `
        -Expected "24.9|false" `
        -Message "One published category remains usable without triggering a count-based cap"

    Assert-SqlEquals `
        -Sql @'
select md5(string_agg(
    jsonb_build_array(city_insee_code, year, category_id, incident_count, rate_per_1000,
        publication_status::text, source, count_unit, insee_pop, insee_pop_millesime,
        insee_log, insee_log_millesime, complement_info_nombre, complement_info_taux,
        rate_denominator)::text,
    E'\n' order by id
)) from crime_stats;
'@ `
        -Expected $rawValuesBeforeExposureMigration `
        -Message "The absolute exposure migration must not modify raw official SSMSI rows"

    & $refreshScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    Assert-SqlEquals `
        -Sql "select complement_info_nombre || '|' || complement_info_taux from search_metrics_city_year_category where snapshot_id = (select snapshot_id from search_metrics_active where singleton) and city_insee_code='Q0001' and year=2025 and category_code='ssmsi-74a195792dd119f60822e61df3587522';" `
        -Expected "999.000000|25.000000" `
        -Message "Category snapshots must preserve complement fields used by v2 calculations"

    Assert-SqlEquals `
        -Sql "select published_basket_category_count || '|' || estimated_basket_category_count || '|' || effective_basket_category_count || '|' || low_volume_cap_applied || '|' || comparative_index_provenance from search_metrics_city_year_comparative where snapshot_id = (select snapshot_id from search_metrics_active where singleton) and city_insee_code='Q0001' and year=2025;" `
        -Expected "1|0|1|false|published-only" `
        -Message "Comparative snapshots must preserve absolute exposure coverage and provenance"

    Assert-SqlEquals `
        -Sql "select effective_basket_category_count || '|' || low_volume_cap_applied || '|' || basket_index_coverage from search_metrics_city_year_comparative where snapshot_id = (select snapshot_id from search_metrics_active where singleton) and city_insee_code='V3P01' and year=2025;" `
        -Expected "6|true|1.00000000000000000000" `
        -Message "The active snapshot must preserve exposure coverage and cap metadata"

    Assert-SqlEquals `
        -Sql "select comparative_index::text || '|' || comparative_index_provenance from search_metrics_city_year_comparative where snapshot_id = (select snapshot_id from search_metrics_active where singleton) and city_insee_code='V3P02' and year=2025;" `
        -Expected "24.9|published-only" `
        -Message "The active snapshot must preserve one-decimal exposure scores"

    Assert-SqlEquals `
        -Sql "select availability_mask || '|' || estimated_availability_mask from search_metrics_city_year_comparative where snapshot_id = (select snapshot_id from search_metrics_active where singleton) and city_insee_code='V3P01' and year=2025;" `
        -Expected "47|16" `
        -Message "The active snapshot must retain published versus estimated category provenance"

    Assert-SqlEquals `
        -Sql "select round(category_exposure_score, 4) || '|' || category_exposure_source from search_metrics_city_year_category where snapshot_id = (select snapshot_id from search_metrics_active where singleton) and city_insee_code='V3P01' and year=2025 and category_code='ssmsi-a2601b900aa009440624697e1d74e4a9';" `
        -Expected "100.0000|department-masked-average" `
        -Message "The category snapshot must preserve the estimated provenance of its derived score"

    $snapshotBeforeFailure = (Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    Invoke-Psql -Sql @'
create function fail_v2_snapshot_for_test() returns trigger
language plpgsql as $function$
begin
    raise exception 'forced v2 snapshot failure';
end;
$function$;
create trigger fail_v2_snapshot_for_test
before insert on search_metrics_city_year_comparative
for each row execute function fail_v2_snapshot_for_test();
'@ | Out-Null

    $refreshFailed = $false
    try {
        & $refreshScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres"
    }
    catch {
        $refreshFailed = $true
    }

    if (-not $refreshFailed) {
        throw "A forced v2 refresh failure should be reported."
    }

    Assert-SqlEquals `
        -Sql "select snapshot_id from search_metrics_active where singleton;" `
        -Expected $snapshotBeforeFailure `
        -Message "A failed v2 refresh must preserve the active snapshot pointer"
    Assert-SqlEquals `
        -Sql "select count(*) from search_metric_snapshots;" `
        -Expected "1" `
        -Message "A failed v2 refresh must roll back its partial snapshot"
    Invoke-Psql -Sql "drop trigger fail_v2_snapshot_for_test on search_metrics_city_year_comparative; drop function fail_v2_snapshot_for_test();" | Out-Null

    Write-Host "Absolute exposure index database test passed."
}
finally {
    docker rm -f $ContainerName 2>$null | Out-Null
}
