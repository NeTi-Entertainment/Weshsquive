param(
    [string]$DatabaseName = "app_criminalite_dvf_test",
    [string]$ContainerName = "app-criminalite-dvf-test"
)

$ErrorActionPreference = "Stop"
$ContainerName = "$ContainerName-$PID"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$importer = Join-Path $PSScriptRoot "import_property_sales_dvf.ps1"
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-dvf-test-$PID"

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

function Write-GzipFixture {
    param(
        [string]$Path,
        [string[]]$Lines,
        [System.Text.Encoding]$Encoding = [System.Text.UTF8Encoding]::new($false)
    )
    $file = [System.IO.File]::Create($Path)
    try {
        $gzip = [System.IO.Compression.GZipStream]::new($file, [System.IO.Compression.CompressionMode]::Compress)
        try {
            $writer = [System.IO.StreamWriter]::new($gzip, $Encoding)
            try { foreach ($line in $Lines) { $writer.WriteLine($line) } }
            finally { $writer.Dispose() }
        }
        finally { $gzip.Dispose() }
    }
    finally { $file.Dispose() }
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

    Invoke-Psql -Sql "insert into regions(code,name) values ('75','Nouvelle-Aquitaine'); insert into departments(code,name,region_code) values ('33','Gironde','75'); insert into cities(insee_code,name,department_code,region_code) values ('33001','Alpha','33','75'),('33002','Beta','33','75');" | Out-Null

    $partialRemoteError = ""
    try {
        & $importer -Year 2025 -SourceUrls @("https://files.data.gouv.fr/geo-dvf/latest/csv/2025/departements/ZZ.csv.gz") `
            -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    }
    catch { $partialRemoteError = $_.Exception.Message }
    if ($partialRemoteError -notmatch "complete national") {
        throw "A partial remote DVF import should be rejected before download, got '$partialRemoteError'."
    }

    $header = "id_mutation,date_mutation,nature_mutation,valeur_fonciere,code_commune,id_local,type_local,surface_reelle_bati"
    $vefaNature = "Vente en l'$([char]0x00e9)tat futur d'ach$([char]0x00e8)vement"
    $fixture = Join-Path $workDir "dvf-2025.csv.gz"
    Write-GzipFixture -Path $fixture -Lines @(
        $header,
        'M1,2025-01-02,Vente,100000,33001,L1,Appartement,100',
        'M2,2025-02-02,Vente,200000,33001,L2,Appartement,100',
        'M2,2025-02-02,Vente,200000,33001,L2,Appartement,100',
        'M3,2025-03-02,Vente,300000,33001,L3,Maison,100',
        'M3,2025-03-02,Vente,300000,33001,D3,Dépendance,20',
        'M4,2025-04-02,Vente,400000,33001,L4,Appartement,100',
        'M4,2025-04-02,Vente,400000,33001,L5,Appartement,90',
        'M5,2025-05-02,Vente,500000,33001,L6,Maison,100',
        'M5,2025-05-02,Vente,500000,33002,D6,Dépendance,20',
        'M6,2025-06-02,Vente,600000,33001,L7,Maison,0',
        'M7,2025-07-02,Vente,"400000,50",33001,L8,Appartement,"100,00"',
        'M8,2025-08-02,Vente,200000,33001,L9,Appartement,1',
        "M9,2025-09-02,$vefaNature,500000,33001,L10,Appartement,100",
        'UNKNOWN,2025-10-02,Vente,100000,99999,L11,Appartement,100',
        'OTHER,2025-11-02,Echange,100000,33001,L12,Appartement,100'
    )

    & $importer -Year 2025 -SourceUrls @($fixture) -SourceLastModified "2026-04-01T00:00:00Z" `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    if ($LASTEXITCODE -ne 0) { throw "Initial DVF import failed." }

    Assert-SqlEquals -Sql "select count(*) from property_sale_observations where source_year=2025;" -Expected "6" -Message "Only six eligible single-property mutations should be retained"
    Assert-SqlEquals -Sql "select sale_value::integer || '|' || built_area::integer from property_sale_observations where mutation_id='M8';" -Expected "200000|1" -Message "The official extreme mutation should remain stored"
    Assert-SqlEquals -Sql "select value_per_m2::integer || '|' || sample_count from property_market_metrics where city_insee_code='33001' and year=2025 and metric_kind='sale' and property_type='all';" -Expected "3000|5" -Message "The extreme mutation should be excluded only from the derived median"
    Assert-SqlEquals -Sql "select metadata->>'retainedMutationCount' from import_batches where source_system='dvf-geolocated' and source_year=2025 order by id desc limit 1;" -Expected "6" -Message "The import batch should record retained volume"
    Assert-SqlEquals -Sql "select jsonb_array_length(metadata->'sourceFileSha256') from import_batches where source_system='dvf-geolocated' and source_year=2025 order by id desc limit 1;" -Expected "1" -Message "The import batch should retain a fingerprint for every imported file"
    Assert-SqlEquals -Sql "select (length(metadata->>'contentManifestHash') = 64)::text from import_batches where source_system='dvf-geolocated' and source_year=2025 order by id desc limit 1;" -Expected "true" -Message "The import batch should retain a content-derived manifest"

    & $importer -Year 2025 -SourceUrls @($fixture) -SourceLastModified "2026-04-01T00:00:00Z" `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    Assert-SqlEquals -Sql "select count(*) from property_sale_observations where source_year=2025;" -Expected "6" -Message "A repeated import should not duplicate mutations"

    Invoke-Psql -Sql "insert into import_batches(source_system,source_year,status,metadata,completed_at) values ('dvf-geolocated',2024,'completed','{}',now()); insert into property_sale_observations(source_system,source_year,mutation_id,city_insee_code,mutation_date,mutation_nature,property_type,sale_value,built_area,import_batch_id) values ('dvf-geolocated',2024,'OLD','33001','2024-01-01','Vente','house',100000,100,(select max(id) from import_batches where source_year=2024));" | Out-Null

    $revision = Join-Path $workDir "dvf-2025-revision.csv.gz"
    Write-GzipFixture -Path $revision -Lines @($header, 'R1,2025-12-01,Adjudication,250000,33001,R1,Maison,100')
    & $importer -Year 2025 -SourceUrls @($revision) -SourceLastModified "2026-10-01T00:00:00Z" `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    Assert-SqlEquals -Sql "select count(*) from property_sale_observations where source_year=2025;" -Expected "1" -Message "A revision should replace its year"
    Assert-SqlEquals -Sql "select count(*) from property_sale_observations where source_year=2024;" -Expected "1" -Message "A revision should not touch other years"

    $officialHeader = "id_mutation,date_mutation,nature_mutation,valeur_fonciere,code_commune,numero_disposition,adresse_numero,adresse_code_voie,lot1_numero,lot2_numero,lot3_numero,lot4_numero,lot5_numero,type_local,surface_reelle_bati,nombre_pieces_principales"
    $officialShape = Join-Path $workDir "dvf-2023-official-shape.csv.gz"
    Write-GzipFixture -Path $officialShape -Lines @(
        $officialHeader,
        'G1,2023-01-01,Vente,200000,33001,1,10,A001,101,,,,,Appartement,50,2',
        'G1,2023-01-01,Vente,200000,33001,1,10,A001,101,,,,,Appartement,50,2',
        'G2,2023-02-01,Vente,300000,33001,1,12,A001,201,,,,,Appartement,50,2',
        'G2,2023-02-01,Vente,300000,33001,1,12,A001,202,,,,,Appartement,50,2',
        'G3,2023-03-01,Vente,250000,33001,1,14,A001,,,,,,Maison,100,4',
        'G3,2023-03-01,Vente,250000,33001,1,14,A001,,,,,,Maison,100,4'
    )
    & $importer -Year 2023 -SourceUrls @($officialShape) `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    Assert-SqlEquals -Sql "select count(*) from property_sale_observations where source_year=2023;" -Expected "2" -Message "The official DVF shape without id_local should retain one apartment and one house mutation"

    $windows1252 = [System.Text.Encoding]::GetEncoding(1252)
    $windowsFixture = Join-Path $workDir "dvf-2022-windows-1252.csv.gz"
    Write-GzipFixture -Path $windowsFixture -Encoding $windows1252 -Lines @(
        $header,
        "W1,2022-01-01,$vefaNature,200000,33001,W1,Appartement,50"
    )
    & $importer -Year 2022 -SourceUrls @($windowsFixture) `
        -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    Assert-SqlEquals -Sql "select count(*) from property_sale_observations where source_year=2022 and mutation_id='W1';" -Expected "1" -Message "A Windows-1252 DVF source should be transcoded and retain accented official values"

    $invalid = Join-Path $workDir "dvf-invalid.csv.gz"
    Write-GzipFixture -Path $invalid -Lines @('id_mutation,date_mutation', 'BROKEN,2025-01-01')
    $failed = $false
    try {
        & $importer -Year 2025 -SourceUrls @($invalid) `
            -ContainerName $ContainerName -DatabaseName $DatabaseName -DatabaseUser postgres -DatabasePassword postgres
    }
    catch { $failed = $true }
    if (-not $failed) { throw "An invalid DVF schema should fail closed." }
    Assert-SqlEquals -Sql "select mutation_id from property_sale_observations where source_year=2025;" -Expected "R1" -Message "A failed revision should preserve the active year"

    Write-Host "DVF property sale import test passed."
}
finally {
    docker rm -f $ContainerName 2>$null | Out-Null
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
