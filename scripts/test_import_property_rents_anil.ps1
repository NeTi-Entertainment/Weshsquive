param(
    [string]$DatabaseName = "app_criminalite_anil_test",
    [string]$ContainerName = "app-criminalite-anil-test"
)

$ErrorActionPreference = "Stop"
$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$importer = Join-Path $PSScriptRoot "import_property_rents_anil.ps1"
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-anil-test-$PID"

function Invoke-Psql {
    param([Parameter(Mandatory = $true)][string]$Sql, [switch]$TuplesOnly)
    $arguments = @("exec", "-e", "PGPASSWORD=postgres", $ContainerName, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", $DatabaseName)
    if ($TuplesOnly) { $arguments += @("-t", "-A") }
    $arguments += @("-c", $Sql)
    $output = docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $Sql" }
    return $output
}

function Assert-SqlEquals {
    param([string]$Sql, [string]$Expected, [string]$Message)
    $actual = (Invoke-Psql -Sql $Sql -TuplesOnly).Trim()
    if ($actual -ne $Expected) { throw "$Message. Expected '$Expected', got '$actual'." }
}

docker rm -f $ContainerName 2>$null | Out-Null
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    docker run --name $ContainerName -e POSTGRES_PASSWORD=postgres -d postgis/postgis:16-3.4 | Out-Null
    $initComplete = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        $logs = docker logs $ContainerName 2>&1
        $ErrorActionPreference = $previous
        if (($logs -join "`n") -match "PostgreSQL init process complete") { $initComplete = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $initComplete) { throw "PostgreSQL initialization did not complete." }

    docker exec -e PGPASSWORD=postgres $ContainerName createdb -U postgres $DatabaseName
    foreach ($migration in (Get-ChildItem $migrationDir -Filter "*.sql" -File | Sort-Object Name)) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)" | Out-Null
        docker exec -e PGPASSWORD=postgres $ContainerName psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($migration.Name)" }
    }

    Invoke-Psql -Sql "insert into regions(code,name) values ('75','Nouvelle-Aquitaine'),('06','Mayotte'); insert into departments(code,name,region_code) values ('33','Gironde','75'),('976','Mayotte','06'); insert into cities(insee_code,name,department_code,region_code) values ('33001','Alpha','33','75'),('33002','Beta','33','75'),('33003','Gamma','33','75'),('97601','Mayotte Ville','976','06');" | Out-Null

    $header = '"id_zone";"INSEE_C";"LIBGEO";"EPCI";"DEP";"REG";"loypredm2";"lwr.IPm2";"upr.IPm2";"TYPPRED";"nbobs_com";"nbobs_mail";"R2_adj"'
    $apartments = Join-Path $workDir "apartments.csv"
    $houses = Join-Path $workDir "houses.csv"
    [System.IO.File]::WriteAllLines($apartments, @(
        $header,
        '"1";"33001";"Alpha";"E";"33";"75";12,5;10,0;14,0;"commune";30;50;0,5',
        '"2";"33002";"Beta";"E";"33";"75";14,0;12,0;16,0;"maille";100;120;0,8',
        '"3";"33003";"Gamma";"E";"33";"75";;;;"commune";;;',
        '"4";"97601";"Mayotte Ville";"E";"976";"06";20,0;18,0;22,0;"commune";50;60;0,9',
        '"5";"99999";"Unknown";"E";"99";"99";10,0;9,0;11,0;"commune";40;50;0,7'
    ), [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllLines($houses, @(
        $header,
        '"1";"33001";"Alpha";"E";"33";"75";15,0;13,0;17,0;"commune";29;40;0,8',
        '"2";"33002";"Beta";"E";"33";"75";12,0;15,0;14,0;"commune";40;50;0,8'
    ), [System.Text.Encoding]::ASCII)

    & $importer -Year 2025 -ApartmentFileUrl $apartments -HouseFileUrl $houses -SourceLastModified "2025-12-11T14:58:19Z" `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres

    Assert-SqlEquals -Sql "select count(*) from property_rent_observations where source_year=2025;" -Expected "6" -Message "Known apartment and house observations should be retained"
    Assert-SqlEquals -Sql "select estimated_rent_per_m2::text || '|' || commune_observation_count || '|' || adjusted_r2::text from property_rent_observations where city_insee_code='33001' and property_type='apartment';" -Expected "12.5000|30|0.50000000" -Message "Official ANIL decimal values should be preserved"
    Assert-SqlEquals -Sql "select coalesce(estimated_rent_per_m2::text,'NULL') || '|' || coalesce(commune_observation_count::text,'NULL') from property_rent_observations where city_insee_code='33003' and property_type='apartment';" -Expected "NULL|NULL" -Message "Missing ANIL values should remain null"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='rent' and property_type='apartment';" -Expected "published" -Message "Exact ANIL quality boundaries should be published"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='rent' and property_type='house';" -Expected "insufficient-quality" -Message "Twenty-nine observations should be gray"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33002' and year=2025 and metric_kind='rent' and property_type='apartment';" -Expected "non-communal-estimate" -Message "Grid estimates should be gray"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='33002' and year=2025 and metric_kind='rent' and property_type='house';" -Expected "invalid-value" -Message "An inverted interval should be gray"
    Assert-SqlEquals -Sql "select display_status from property_market_metrics where city_insee_code='97601' and year=2025 and metric_kind='rent' and property_type='apartment';" -Expected "source-uncovered" -Message "Mayotte should stay gray"

    & $importer -Year 2025 -ApartmentFileUrl $apartments -HouseFileUrl $houses `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    Assert-SqlEquals -Sql "select count(*) from property_rent_observations where source_year=2025;" -Expected "6" -Message "A repeated ANIL import should not duplicate rows"

    $revisionApartments = Join-Path $workDir "apartments-revision.csv"
    $revisionHouses = Join-Path $workDir "houses-revision.csv"
    [System.IO.File]::WriteAllLines($revisionApartments, @($header, '"1";"33001";"Alpha";"E";"33";"75";13,0;11,0;15,0;"commune";31;51;0,6'), [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllLines($revisionHouses, @($header, '"1";"33001";"Alpha";"E";"33";"75";16,0;14,0;18,0;"commune";35;45;0,7'), [System.Text.Encoding]::ASCII)
    & $importer -Year 2025 -ApartmentFileUrl $revisionApartments -HouseFileUrl $revisionHouses `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    Assert-SqlEquals -Sql "select count(*) from property_rent_observations where source_year=2025;" -Expected "2" -Message "A revised publication should replace its year"
    Assert-SqlEquals -Sql "select value_per_m2::integer from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='rent' and property_type='house';" -Expected "16" -Message "A revision should refresh derived rents"

    $coverageApartments = Join-Path $workDir "apartments-insufficient-coverage.csv"
    $coverageHouses = Join-Path $workDir "houses-insufficient-coverage.csv"
    $coverageRows = @(
        $header,
        '"1";"33001";"Alpha";"E";"33";"75";13,0;11,0;15,0;"commune";31;51;0,6',
        '"2";"99999";"Unknown";"E";"99";"99";13,0;11,0;15,0;"commune";31;51;0,6'
    )
    [System.IO.File]::WriteAllLines($coverageApartments, $coverageRows, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllLines($coverageHouses, $coverageRows, [System.Text.Encoding]::ASCII)
    $coverageError = ""
    try {
        & $importer -Year 2025 -ApartmentFileUrl $coverageApartments -HouseFileUrl $coverageHouses `
            -EnforceNationalCoverage -NationalMinimumRowsPerType 2 `
            -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    }
    catch { $coverageError = $_.Exception.Message }
    if ($coverageError -notmatch "coverage") { throw "Insufficient retained ANIL coverage should fail closed, got '$coverageError'." }
    Assert-SqlEquals -Sql "select count(*) from property_rent_observations where source_year=2025;" -Expected "2" -Message "A failed coverage validation should preserve active ANIL data"

    $yearError = ""
    try {
        & $importer -Year 2025 `
            -ApartmentFileUrl "https://static.data.gouv.fr/resources/carte-des-loyers-indicateurs-de-loyers-dannonce-par-commune-en-2024/example-apartment.csv" `
            -HouseFileUrl "https://static.data.gouv.fr/resources/carte-des-loyers-indicateurs-de-loyers-dannonce-par-commune-en-2024/example-house.csv" `
            -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    }
    catch { $yearError = $_.Exception.Message }
    if ($yearError -notmatch "year") { throw "A mismatched ANIL source vintage should fail before download, got '$yearError'." }

    $invalid = Join-Path $workDir "invalid.csv"
    [System.IO.File]::WriteAllLines($invalid, @('"INSEE_C";"loypredm2"', '"33001";99'), [System.Text.Encoding]::ASCII)
    $failed = $false
    try {
        & $importer -Year 2025 -ApartmentFileUrl $invalid -HouseFileUrl $revisionHouses `
            -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    }
    catch { $failed = $true }
    if (-not $failed) { throw "An invalid ANIL schema should fail closed." }
    Assert-SqlEquals -Sql "select estimated_rent_per_m2::integer from property_rent_observations where city_insee_code='33001' and source_year=2025 and property_type='apartment';" -Expected "13" -Message "A failed revision should preserve active ANIL data"

    Write-Host "ANIL rent import test passed."
}
finally {
    docker rm -f $ContainerName 2>$null | Out-Null
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
