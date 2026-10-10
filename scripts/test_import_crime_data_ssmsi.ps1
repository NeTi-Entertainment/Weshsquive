param(
    [string]$DatabaseName = "app_criminalite_crime_test",
    [string]$ContainerName = "app-criminalite-crime-test"
)

$ErrorActionPreference = "Stop"

$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$crimeScript = Join-Path $PSScriptRoot "import_crime_data_ssmsi.ps1"
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-crime-fixtures-$PID"

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

        if ($migration.Name -eq "003_ssmsi_units_and_denominators.sql") {
            docker exec -e PGPASSWORD=postgres $ContainerName `
                psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" `
                | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "The SSMSI metadata migration should be safely repeatable."
            }
        }
    }
}

docker rm -f $ContainerName 2>$null | Out-Null

try {
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

    @'
CODGEO_2027;annee;indicateur;unite_de_compte;nombre;taux_pour_mille;est_diffuse;insee_pop;insee_pop_millesime;insee_log;insee_log_millesime;complement_info_nombre;complement_info_taux
75056;2025;Cambriolages de logement;Infraction;4;8,0000000;diff;1044;2023;500;2023;NA;NA
75056;2025;Vols de véhicule;Infraction;3;2,8736000;diff;1044;2023;500;2023;NA;NA
75056;2025;Vols dans les véhicules;Infraction;5;4,7893000;diff;1044;2023;500;2023;NA;NA
75056;2025;Destructions et dégradations volontaires;Infraction;6;5,7471000;diff;1044;2023;500;2023;NA;NA
75056;2025;Violences physiques hors cadre familial;Victime;7;6,7050000;diff;1044;2023;500;2023;NA;NA
75056;2025;Trafic de stupéfiants;Mis en cause;8;7,6628000;diff;1044;2023;500;2023;NA;NA
75056;2025;Violences sexuelles;Victime;NA;NA;ndiff;1044;2023;500;2023;2,0000000;1,9000000
75001;2025;Violences sexuelles;Victime;NA;NA;ndiff;1200;2023;600;2023;2,0;1,9000
75056;2025;Usage de stupéfiants;Auteur;0;0,0000000;diff;1044;2023;500;2023;NA;NA
75056;2025;Indicateur futur non documente;Infraction;2;1,9157000;diff;1044;2023;500;2023;NA;NA
69123;2024;Cambriolages de logement;Infraction;8;1,5400000;diff;519127;2023;280000;2023;NA;NA
99999;2025;Cambriolages de logement;Infraction;12;5,0000000;diff;2400;2023;1000;2023;NA;NA
'@ | Set-Content -Path (Join-Path $fixtureDir "ssmsi.csv") -Encoding utf8

    @'
CODGEO_2027;annee;indicateur;unite_de_compte;nombre;taux_pour_mille;est_diffuse;insee_pop;insee_pop_millesime;insee_log;insee_log_millesime;complement_info_nombre;complement_info_taux
75056;2025;Cambriolages de logement;Infraction;5;9,0000000;diff;1044;2023;500;2023;NA;NA
75056;2025;Violences sexuelles;Victime;NA;NA;ndiff;1044;2023;500;2023;2,0000000;1,9000000
'@ | Set-Content -Path (Join-Path $fixtureDir "ssmsi-revision.csv") -Encoding utf8

    @'
CODGEO_2027;annee;indicateur;unite_de_compte;nombre;taux_pour_mille;est_diffuse;insee_pop;insee_pop_millesime;insee_log;insee_log_millesime;complement_info_nombre;complement_info_taux
75056;2025;Cambriolages de logement;Infraction;4;8,0000000;diff;1044;2023;500;2023;2,0000000;4,0000000
'@ | Set-Content -Path (Join-Path $fixtureDir "ssmsi-invalid-published-complement.csv") -Encoding utf8

    @'
CODGEO_2027;annee;indicateur;unite_de_compte;nombre;taux_pour_mille;est_diffuse;insee_pop;insee_pop_millesime;insee_log;insee_log_millesime;complement_info_nombre;complement_info_taux
75056;2025;Violences sexuelles;Victime;NA;NA;ndiff;1044;2023;500;2023;2,0000000;1,9000000
75001;2025;Violences sexuelles;Victime;NA;NA;ndiff;1200;2023;600;2023;3,0000000;2,1000000
'@ | Set-Content -Path (Join-Path $fixtureDir "ssmsi-duplicate-department-complement.csv") -Encoding utf8

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

insert into cities (insee_code, name, department_code, region_code, source, reference_population, population_year)
values
    ('75056', 'Paris', '75', '11', 'fixture', 1044, 2023),
    ('75001', 'Second Paris fixture', '75', '11', 'fixture', 1200, 2023),
    ('69123', 'Lyon', '69', '84', 'fixture', 519127, 2023);
"@ | Out-Null

    & $crimeScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -CrimeFileUrl (Join-Path $fixtureDir "ssmsi.csv") `
        -Year 2025 `
        -GeographyYear 2027 `
        -Source "test-ssmsi" `
        -SourceLastModified "2026-07-09T13:59:52+02:00"

    $categorySnapshotDiffCount = @"
select count(*) from (
    (select city_insee_code, year, category_id, category_code, category_label,
        incident_count, rate_per_1000, publication_status::text, count_unit,
        rate_denominator_reference, rate_denominator, insee_pop, insee_pop_millesime,
        insee_log, insee_log_millesime, complement_info_nombre, complement_info_taux
     from search_metrics_city_year_category
     where snapshot_id = (select snapshot_id from search_metrics_active where singleton)
     except all
     select city_insee_code, year, category_id, category_code, category_label,
        incident_count, rate_per_1000, publication_status::text, count_unit,
        rate_denominator_reference, rate_denominator, insee_pop, insee_pop_millesime,
        insee_log, insee_log_millesime, complement_info_nombre, complement_info_taux
     from city_year_category_metrics)
    union all
    (select city_insee_code, year, category_id, category_code, category_label,
        incident_count, rate_per_1000, publication_status::text, count_unit,
        rate_denominator_reference, rate_denominator, insee_pop, insee_pop_millesime,
        insee_log, insee_log_millesime, complement_info_nombre, complement_info_taux
     from city_year_category_metrics
     except all
     select city_insee_code, year, category_id, category_code, category_label,
        incident_count, rate_per_1000, publication_status::text, count_unit,
        rate_denominator_reference, rate_denominator, insee_pop, insee_pop_millesime,
        insee_log, insee_log_millesime, complement_info_nombre, complement_info_taux
     from search_metrics_city_year_category
     where snapshot_id = (select snapshot_id from search_metrics_active where singleton))
) differences;
"@
    Assert-SqlEquals `
        -Sql $categorySnapshotDiffCount `
        -Expected "0" `
        -Message "The active category snapshot should exactly match the reference view"

    $comparativeSnapshotDiffCount = @"
select count(*) from (
    (select city_insee_code, year, population, population_year, population_band,
        published_category_count, total_category_count, coverage_ratio, availability_mask,
        published_basket_category_count, cohort_size, estimated_basket_category_count,
        comparable_basket_category_count, estimated_availability_mask,
        minimum_reference_cohort_size, comparative_index_provenance, comparative_index_status,
        comparative_index, comparative_index_confidence, basket_version
     from search_metrics_city_year_comparative
     where snapshot_id = (select snapshot_id from search_metrics_active where singleton)
     except all
     select city_insee_code, year, population, population_year, population_band,
        published_category_count, total_category_count, coverage_ratio, availability_mask,
        published_basket_category_count, cohort_size, estimated_basket_category_count,
        comparable_basket_category_count, estimated_availability_mask,
        minimum_reference_cohort_size, comparative_index_provenance, comparative_index_status,
        comparative_index, comparative_index_confidence, basket_version
     from city_year_comparative_metrics)
    union all
    (select city_insee_code, year, population, population_year, population_band,
        published_category_count, total_category_count, coverage_ratio, availability_mask,
        published_basket_category_count, cohort_size, estimated_basket_category_count,
        comparable_basket_category_count, estimated_availability_mask,
        minimum_reference_cohort_size, comparative_index_provenance, comparative_index_status,
        comparative_index, comparative_index_confidence, basket_version
     from city_year_comparative_metrics
     except all
     select city_insee_code, year, population, population_year, population_band,
        published_category_count, total_category_count, coverage_ratio, availability_mask,
        published_basket_category_count, cohort_size, estimated_basket_category_count,
        comparable_basket_category_count, estimated_availability_mask,
        minimum_reference_cohort_size, comparative_index_provenance, comparative_index_status,
        comparative_index, comparative_index_confidence, basket_version
     from search_metrics_city_year_comparative
     where snapshot_id = (select snapshot_id from search_metrics_active where singleton))
) differences;
"@
    Assert-SqlEquals `
        -Sql $comparativeSnapshotDiffCount `
        -Expected "0" `
        -Message "The active comparative snapshot should exactly match the reference view"

    $snapshotBeforeFailure = (Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    Invoke-Psql -Sql @'
create function fail_search_snapshot_for_test() returns trigger
language plpgsql as $function$
begin
    raise exception 'forced snapshot failure';
end;
$function$;
create trigger fail_search_snapshot_for_test
before insert on search_metrics_city_year_comparative
for each row execute function fail_search_snapshot_for_test();
'@ | Out-Null

    $refreshFailed = $false
    try {
        & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres"
    }
    catch {
        $refreshFailed = $true
    }

    if (-not $refreshFailed) {
        throw "A forced refresh failure should be reported."
    }

    Assert-SqlEquals `
        -Sql "select snapshot_id from search_metrics_active where singleton;" `
        -Expected $snapshotBeforeFailure `
        -Message "A failed refresh must keep the previous snapshot active"
    Assert-SqlEquals `
        -Sql "select count(*) from search_metric_snapshots;" `
        -Expected "1" `
        -Message "A failed refresh must roll back its partial generation"
    Invoke-Psql -Sql "drop trigger fail_search_snapshot_for_test on search_metrics_city_year_comparative; drop function fail_search_snapshot_for_test();" | Out-Null

    & $crimeScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -CrimeFileUrl (Join-Path $fixtureDir "ssmsi.csv") `
        -Year 2025 `
        -GeographyYear 2027 `
        -Source "test-ssmsi" `
        -SourceLastModified "2026-07-09T13:59:52+02:00"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_categories;" `
        -Expected "9" `
        -Message "Crime categories should be imported once"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats;" `
        -Expected "10" `
        -Message "Crime stats import should be idempotent, filtered by year and skip unknown cities"

    Assert-SqlEquals `
        -Sql "select metadata->>'catalogLastModified' from import_batches where source_system = 'test-ssmsi' and source_year = 2025 order by completed_at desc limit 1;" `
        -Expected "2026-07-09T13:59:52+02:00" `
        -Message "SSMSI import metadata should retain the official catalog revision timestamp"

    Assert-SqlEquals `
        -Sql "select metadata->'sourceColumns'->>0 from import_batches where source_system = 'test-ssmsi' and source_year = 2025 order by completed_at desc limit 1;" `
        -Expected "CODGEO_2027" `
        -Message "SSMSI import metadata should preserve the actual geography column name"

    $crimeBatchCountBeforeGeographyMismatch = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" -TuplesOnly).Trim()
    $geographyMismatchFailed = $false
    try {
        & $crimeScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -CrimeFileUrl (Join-Path $fixtureDir "ssmsi.csv") `
            -Year 2025 `
            -GeographyYear 2026 `
            -Source "test-ssmsi"
    }
    catch {
        $geographyMismatchFailed = $true
    }

    if (-not $geographyMismatchFailed) {
        throw "An SSMSI geography header different from the catalog year should fail before import."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" `
        -Expected $crimeBatchCountBeforeGeographyMismatch `
        -Message "A mismatched geography year must not create an import batch"

    Assert-SqlEquals `
        -Sql "select incident_count || ':' || rate_per_1000 || ':' || publication_status from crime_stats cs join crime_categories cc on cc.id = cs.category_id where city_insee_code = '75056' and year = 2025 and cc.label = 'Cambriolages de logement';" `
        -Expected "4:8.0000:published" `
        -Message "Published SSMSI values should keep count and rate"

    Assert-SqlEquals `
        -Sql "select count(*) || ':' || count(*) filter (where cc.label = 'Cambriolages de logement' and cc.rate_denominator_reference = 'housing' and cs.rate_denominator = 'housing') || ':' || count(*) filter (where cc.label <> 'Cambriolages de logement' and cc.rate_denominator_reference = 'population' and cs.rate_denominator = 'population') from crime_stats cs join crime_categories cc on cc.id = cs.category_id where cs.city_insee_code = '75056' and cs.year = 2025 and cc.code in ('ssmsi-78384436563146dc6167ea53b7b5e0cd','ssmsi-74a195792dd119f60822e61df3587522','ssmsi-d3e9d2e40d72b8850d5283eb73bdc928','ssmsi-bf6b19b3e53b90f6594ec2e8303c5778','ssmsi-a2601b900aa009440624697e1d74e4a9','ssmsi-bdbeb8ca73503f8264dab16159795328');" `
        -Expected "6:1:5" `
        -Message "All six comparative basket categories must use the official denominator reference"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats where publication_status = 'published' and (complement_info_nombre is not null or complement_info_taux is not null);" `
        -Expected "0" `
        -Message "Published diff rows must not retain complement values"

    Assert-SqlEquals `
        -Sql "select count_unit || ':' || insee_pop || ':' || insee_pop_millesime || ':' || insee_log || ':' || insee_log_millesime || ':' || rate_denominator from crime_stats cs join crime_categories cc on cc.id = cs.category_id where city_insee_code = '75056' and year = 2025 and cc.label = 'Cambriolages de logement';" `
        -Expected "Infraction:1044:2023:500:2023:housing" `
        -Message "Official unit, denominators, vintages, and known housing base should be retained"

    Assert-SqlEquals `
        -Sql "select (incident_count is null)::text || ':' || (rate_per_1000 is null)::text || ':' || publication_status || ':' || complement_info_nombre || ':' || complement_info_taux || ':' || count_unit from crime_stats cs join crime_categories cc on cc.id = cs.category_id where city_insee_code = '75056' and year = 2025 and cc.label = 'Violences sexuelles';" `
        -Expected "true:true:masked:2.000000:1.900000:Victime" `
        -Message "Masked statistics should stay null while complements and unit remain separate metadata"

    Assert-SqlEquals `
        -Sql "select count(*) || ':' || count(distinct (cs.complement_info_nombre, cs.complement_info_taux)) from crime_stats cs join crime_categories cc on cc.id = cs.category_id join cities city on city.insee_code = cs.city_insee_code where city.department_code = '75' and cs.year = 2025 and cc.label = 'Violences sexuelles' and cs.publication_status = 'masked';" `
        -Expected "2:1" `
        -Message "Repeated normalized department complement pairs must be accepted for multiple masked communes"

    Assert-SqlEquals `
        -Sql "select incident_count || ':' || rate_per_1000 || ':' || publication_status from crime_stats cs join crime_categories cc on cc.id = cs.category_id where city_insee_code = '75056' and year = 2025 and cc.label = 'Usage de stupéfiants';" `
        -Expected "0:0.0000:published" `
        -Message "A genuinely published zero should remain filterable as zero"

    Assert-SqlEquals `
        -Sql "select incident_count || ':' || rate_per_1000 || ':' || rate_denominator || ':' || (select rate_denominator_reference from crime_categories where id = cs.category_id) from crime_stats cs join crime_categories cc on cc.id = cs.category_id where city_insee_code = '75056' and year = 2025 and cc.label = 'Indicateur futur non documente';" `
        -Expected "2:1.9157:unknown:unknown" `
        -Message "Undocumented indicators should import their official values with an unknown denominator"

    Assert-SqlEquals `
        -Sql "select published_basket_category_count from city_year_comparative_metrics where city_insee_code = '75056' and year = 2025;" `
        -Expected "6" `
        -Message "Unknown or non-basket categories must not increase the comparative-index basket"

    $batchCountBeforeInvalidComplements = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" -TuplesOnly).Trim()
    foreach ($invalidFixture in @(
        "ssmsi-invalid-published-complement.csv",
        "ssmsi-duplicate-department-complement.csv"
    )) {
        $invalidComplementFailed = $false
        try {
            & $crimeScript `
                -ContainerName $ContainerName `
                -DatabaseName $DatabaseName `
                -DatabaseUser "postgres" `
                -DatabasePassword "postgres" `
                -CrimeFileUrl (Join-Path $fixtureDir $invalidFixture) `
                -Year 2025 `
                -GeographyYear 2027 `
                -Source "test-ssmsi" `
                -DeferMetricsRefresh
        }
        catch {
            $invalidComplementFailed = $true
        }

        if (-not $invalidComplementFailed) {
            throw "Invalid SSMSI complements from $invalidFixture should fail before import commit."
        }

        Assert-SqlEquals `
            -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" `
            -Expected $batchCountBeforeInvalidComplements `
            -Message "Rejected SSMSI complements must not create an import batch"
        Assert-SqlEquals `
            -Sql "select count(*) from crime_stats where source = 'test-ssmsi' and year = 2025;" `
            -Expected "10" `
            -Message "Rejected SSMSI complements must preserve the prior annual data"
    }

    Assert-SqlEquals `
        -Sql "select count(*) from pg_attribute where attrelid = 'city_year_comparative_metrics'::regclass and attname in ('published_incident_count','partial_rate_per_1000') and not attisdropped;" `
        -Expected "0" `
        -Message "The derived metrics view must not expose heterogeneous global aggregates"

    $snapshotBeforeDeferredImport = (Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    & $crimeScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -CrimeFileUrl (Join-Path $fixtureDir "ssmsi.csv") `
        -Year 2024 `
        -Source "test-ssmsi" `
        -DeferMetricsRefresh

    Assert-SqlEquals `
        -Sql "select snapshot_id from search_metrics_active where singleton;" `
        -Expected $snapshotBeforeDeferredImport `
        -Message "A deferred SSMSI import should leave the previous metrics snapshot active"

    & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats;" `
        -Expected "11" `
        -Message "A different year should append history without overwriting prior years"

    Assert-SqlEquals `
        -Sql "select count(*) from search_metric_snapshots;" `
        -Expected "2" `
        -Message "Successful refreshes should retain only the two latest generations"

    Assert-SqlEquals `
        -Sql "select incident_count || ':' || rate_per_1000 || ':' || rate_denominator from crime_stats cs join crime_categories cc on cc.id = cs.category_id where city_insee_code = '69123' and year = 2024 and cc.label = 'Cambriolages de logement';" `
        -Expected "8:1.5400:unknown" `
        -Message "A contradictory published rate should be preserved while its observed base is marked unknown"

    $crimeBatchCount = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" -TuplesOnly).Trim()
    $missingCrimeYearFailed = $false
    try {
        & $crimeScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -CrimeFileUrl (Join-Path $fixtureDir "ssmsi.csv") `
            -Year 2026 `
            -Source "test-ssmsi"
    }
    catch {
        $missingCrimeYearFailed = $true
    }

    if (-not $missingCrimeYearFailed) {
        throw "An SSMSI archive without the requested year should fail before import."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" `
        -Expected $crimeBatchCount `
        -Message "A missing SSMSI year must not create an import batch"

    & $crimeScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -CrimeFileUrl (Join-Path $fixtureDir "ssmsi-revision.csv") `
        -Year 2025 `
        -GeographyYear 2027 `
        -Source "test-ssmsi" `
        -DeferMetricsRefresh

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats cs join crime_categories cc on cc.id = cs.category_id where cs.city_insee_code = '75056' and cs.year = 2025 and cc.label = 'Usage de stupéfiants';" `
        -Expected "0" `
        -Message "A revised SSMSI release should remove observations absent from that source revision"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats where year = 2025;" `
        -Expected "2" `
        -Message "Revising one SSMSI year should replace only that year's official observations"

    Invoke-Psql -Sql @"
insert into cities (insee_code, name, department_code, region_code, source)
select lpad((10000 + series.number)::text, 5, '0'), 'Fixture ' || series.number, '75', '11', 'fixture'
from generate_series(1, 1000) as series(number);
"@ | Out-Null

    $batchCountBeforePartialSource = (Invoke-Psql -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" -TuplesOnly).Trim()
    $partialCrimeRevisionFailed = $false
    try {
        & $crimeScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -CrimeFileUrl (Join-Path $fixtureDir "ssmsi-revision.csv") `
            -Year 2025 `
            -GeographyYear 2027 `
            -Source "test-ssmsi" `
            -DeferMetricsRefresh
    }
    catch {
        $partialCrimeRevisionFailed = $true
    }

    if (-not $partialCrimeRevisionFailed) {
        throw "An SSMSI release covering only a small part of a populated database should fail."
    }

    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-ssmsi';" `
        -Expected $batchCountBeforePartialSource `
        -Message "An incomplete SSMSI revision must not create a completed import batch"

    Assert-SqlEquals `
        -Sql "select count(*) from crime_stats where year = 2025;" `
        -Expected "2" `
        -Message "An incomplete SSMSI revision must leave prior annual data intact"

    Write-Host "SSMSI crime data import test passed."
}
finally {
    if (Test-Path $fixtureDir) {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force
    }
    docker rm -f $ContainerName 2>$null | Out-Null
}
