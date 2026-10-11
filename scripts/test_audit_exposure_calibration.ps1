param(
    [string]$DatabaseName = "app_criminalite_exposure_audit_test",
    [string]$ContainerName = "app-criminalite-exposure-audit-test"
)

$ErrorActionPreference = "Stop"
$ContainerName = "$ContainerName-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$applyMigrationsScript = Join-Path $PSScriptRoot "apply_migrations.ps1"
$refreshScript = Join-Path $PSScriptRoot "refresh_search_metrics.ps1"
$auditScript = Join-Path $PSScriptRoot "audit_exposure_calibration.ps1"
$csvPath = Join-Path $env:TEMP "exposure-audit-$PID-$([guid]::NewGuid().ToString('N')).csv"

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [switch]$TuplesOnly
    )

    $arguments = @(
        "exec", "-e", "PGPASSWORD=postgres", $ContainerName,
        "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", $DatabaseName
    )
    if ($TuplesOnly) { $arguments += @("-t", "-A") }
    $arguments += @("-c", $Sql)

    $output = docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $Sql" }
    return $output
}

function Assert-Equal {
    param([string]$Actual, [string]$Expected, [string]$Message)

    if ($Actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

try {
    docker run --name $ContainerName -e POSTGRES_PASSWORD=postgres -d postgis/postgis:16-3.4 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not start disposable PostgreSQL container." }

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
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        docker exec -e PGPASSWORD=postgres $ContainerName pg_isready -U postgres -d postgres *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "Disposable PostgreSQL did not become ready." }

    docker exec -e PGPASSWORD=postgres $ContainerName createdb -U postgres $DatabaseName
    if ($LASTEXITCODE -ne 0) { throw "Could not create disposable test database." }

    & $applyMigrationsScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    Invoke-Psql -Sql @'
insert into regions(code, name) values ('11', 'Ile-de-France');
insert into departments(code, name, region_code) values ('75', 'Paris', '11');
insert into cities(insee_code, name, department_code, region_code, reference_population, population_year) values
    ('A0001', 'Three components with outlier', '75', '11', 900, 2025),
    ('B0001', 'Historical plus estimated', '75', '11', 1200, 2025),
    ('C0001', 'Published high', '75', '11', 25000, 2025),
    ('D0001', 'Unavailable', '75', '11', 400, 2025),
    ('E0001', 'Estimated only', '75', '11', 600, 2025),
    ('F0001', 'Historical only', '75', '11', 1100, 2025),
    ('G0001', 'Published zero', '75', '11', 800, 2025);

insert into crime_categories(code, label, source)
select category_code, 'Audit category ' || availability_bit, 'audit-fixture'
from exposure_index_category_anchors
on conflict (code) do nothing;

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, rate_denominator, complement_info_taux
)
select
    city.insee_code,
    2025,
    category.id,
    case
        when city.insee_code = 'A0001' and anchor.availability_bit = 0 then 1
        when city.insee_code = 'A0001' and anchor.availability_bit in (1, 2) then 0
        when city.insee_code = 'C0001' then 20
        when city.insee_code = 'D0001' and anchor.availability_bit in (0, 1) then 20
        when city.insee_code = 'G0001' then 0
        else null
    end,
    case
        when city.insee_code = 'A0001' and anchor.availability_bit = 0 then anchor.anchor_rate_per_1000
        when city.insee_code = 'A0001' and anchor.availability_bit in (1, 2) then 0
        when city.insee_code = 'C0001' then anchor.anchor_rate_per_1000 * 0.8
        when city.insee_code = 'D0001' and anchor.availability_bit in (0, 1) then 0
        when city.insee_code = 'G0001' then 0
        else null
    end,
    case
        when city.insee_code = 'A0001' and anchor.availability_bit in (0, 1, 2) then 'published'::publication_status
        when city.insee_code = 'C0001' then 'published'::publication_status
        when city.insee_code = 'D0001' and anchor.availability_bit in (0, 1) then 'published'::publication_status
        when city.insee_code = 'G0001' then 'published'::publication_status
        when city.insee_code in ('B0001', 'E0001') then 'masked'::publication_status
        when city.insee_code = 'F0001' then 'masked'::publication_status
        else 'unknown'::publication_status
    end,
    'audit-fixture',
    anchor.count_unit,
    anchor.rate_denominator,
    case
        when city.insee_code in ('B0001', 'E0001') then 0
        else null
    end
from cities city
cross join exposure_index_category_anchors anchor
join crime_categories category on category.code = anchor.category_code
where city.insee_code in ('A0001', 'B0001', 'C0001', 'D0001', 'E0001', 'F0001', 'G0001');

insert into crime_stats(
    city_insee_code, year, category_id, incident_count, rate_per_1000,
    publication_status, source, count_unit, rate_denominator
)
select
    city.insee_code,
    2024,
    category.id,
    20,
    anchor.anchor_rate_per_1000 * case
        when city.insee_code = 'B0001' and anchor.availability_bit = 3 then 2
        when city.insee_code = 'F0001' then 0.4
    end,
    'published',
    'audit-fixture',
    anchor.count_unit,
    anchor.rate_denominator
from cities city
cross join exposure_index_category_anchors anchor
join crime_categories category on category.code = anchor.category_code
where (city.insee_code = 'B0001' and anchor.availability_bit = 3)
   or city.insee_code = 'F0001';
'@ | Out-Null

    & $refreshScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres"

    $snapshotBefore = (Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    $rawBefore = (Invoke-Psql -Sql @'
select md5(string_agg(
    jsonb_build_array(city_insee_code, year, category_id, incident_count, rate_per_1000,
        publication_status::text, source, count_unit, rate_denominator,
        complement_info_taux)::text,
    E'\n' order by id
)) from crime_stats;
'@ -TuplesOnly).Trim()

    $output = (& $auditScript `
        -Year 2025 `
        -CsvPath $csvPath `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" *>&1 | Out-String)
    if ($output -notmatch 'Communes analysées\s*:\s*7') {
        throw "Audit summary did not report the seven fixture cities.`n$output"
    }
    if ($output -notmatch '(?m)^\s*0-10\s+2\s+28\.6%' -or
        $output -notmatch '(?m)^\s*>10-35\s+2\s+28\.6%' -or
        $output -notmatch '(?m)^\s*Indisponible\s+1\s+14\.3%') {
        throw "Score-band distribution did not match the fixture data.`n$output"
    }
    if ($output -notmatch 'Données communales année cible' -or
        $output -notmatch 'Données communales avec historique' -or
        $output -notmatch 'Partiellement estimé' -or
        $output -notmatch 'Entièrement estimé' -or
        $output -notmatch 'Indisponible') {
        throw "Audit summary omitted a global provenance bucket.`n$output"
    }
    if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        throw "Audit did not create its detailed CSV export."
    }

    $rows = @(Import-Csv -LiteralPath $csvPath)
    $codes = @($rows | ForEach-Object city_code)
    foreach ($expectedCode in @('A0001', 'B0001', 'C0001', 'E0001', 'F0001', 'G0001')) {
        if ($expectedCode -notin $codes) { throw "Detailed CSV is missing expected city $expectedCode." }
    }
    if ('D0001' -in $codes) { throw "Unavailable city should not be included among anomalies or 5/6 extremes." }

    $a = $rows | Where-Object city_code -eq 'A0001' | Select-Object -First 1
    Assert-Equal -Actual $a.score -Expected '33.3' -Message "Three-component mean should be rounded to one decimal"
    Assert-Equal -Actual $a.coverage_count -Expected '3' -Message "Exact component coverage should be exported"
    if ($a.audit_reasons -notmatch 'exactement 3/6' -or $a.audit_reasons -notmatch 'composante') {
        throw "Three-component and high-component audit reasons were not exported for A0001."
    }

    $b = $rows | Where-Object city_code -eq 'B0001' | Select-Object -First 1
    Assert-Equal -Actual $b.score -Expected '16.7' -Message "Historical and estimated components should be averaged equally"
    Assert-Equal -Actual $b.baseline_score -Expected '0.0' -Message "Target-year-only fallback reference should use target complements"
    Assert-Equal -Actual $b.history_delta -Expected '16.7' -Message "Historical score delta should be reported"
    Assert-Equal -Actual $b.component_3_source_year -Expected '2024' -Message "Historical source year should be exported"
    Assert-Equal -Actual $b.component_3_source -Expected 'historical-published' -Message "Historical provenance should be exported"
    Assert-Equal -Actual $b.component_3_score -Expected '100.0000' -Message "Historical component score should be exported"

    $d = (Invoke-Psql -Sql "select snapshot_id from search_metrics_active where singleton;" -TuplesOnly).Trim()
    $rawAfter = (Invoke-Psql -Sql @'
select md5(string_agg(
    jsonb_build_array(city_insee_code, year, category_id, incident_count, rate_per_1000,
        publication_status::text, source, count_unit, rate_denominator,
        complement_info_taux)::text,
    E'\n' order by id
)) from crime_stats;
'@ -TuplesOnly).Trim()
    Assert-Equal -Actual $d -Expected $snapshotBefore -Message "Audit must not change the active snapshot pointer"
    Assert-Equal -Actual $rawAfter -Expected $rawBefore -Message "Audit must not modify raw SSMSI rows"

    Write-Host "Exposure calibration audit integration test passed."
}
finally {
    if (Test-Path -LiteralPath $csvPath) {
        Remove-Item -LiteralPath $csvPath -Force
    }
    docker rm -f $ContainerName 2>$null | Out-Null
}
