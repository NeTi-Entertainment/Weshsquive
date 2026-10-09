param(
    [string]$DatabaseName = "app_criminalite_coordinates_test",
    [string]$ContainerName = "app-criminalite-coordinates-test"
)

$ErrorActionPreference = "Stop"
$ContainerName = "$ContainerName-$PID"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$coordinateScript = Join-Path $PSScriptRoot "import_city_coordinates.ps1"
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-coordinate-fixtures-$PID"

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [switch]$TuplesOnly
    )

    $arguments = @(
        "exec", "-e", "PGPASSWORD=postgres", $ContainerName,
        "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", $DatabaseName
    )
    if ($TuplesOnly) {
        $arguments += @("-t", "-A")
    }
    $arguments += @("-c", $Sql)

    $output = docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "psql command failed: $Sql"
    }
    return $output
}

function Assert-SqlEquals {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $actual = (Invoke-Psql -Sql $Sql -TuplesOnly).Trim()
    if ($actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$actual'."
    }
}

docker rm -f $ContainerName 2>$null | Out-Null

try {
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

    $completeRows = @(1..1002 | ForEach-Object {
        [pscustomobject]@{
            code = "{0:D5}" -f (10000 + $_)
            nom = "Commune $_"
            centre = [pscustomobject]@{
                type = "Point"
                coordinates = @((2.0 + ($_ / 10000)), (46.0 + ($_ / 10000)))
            }
        }
    })
    ConvertTo-Json -InputObject $completeRows -Depth 6 -Compress |
        Set-Content -LiteralPath (Join-Path $fixtureDir "coordinates-complete.json") -Encoding utf8

    $partialRows = @($completeRows[0..1] | ForEach-Object {
        [pscustomobject]@{
            code = $_.code
            nom = $_.nom
            centre = [pscustomobject]@{
                type = "Point"
                coordinates = @(9.0, 49.0)
            }
        }
    })
    ConvertTo-Json -InputObject $partialRows -Depth 6 -Compress |
        Set-Content -LiteralPath (Join-Path $fixtureDir "coordinates-partial.json") -Encoding utf8

    docker run `
        --name $ContainerName `
        -e POSTGRES_PASSWORD=postgres `
        -d postgis/postgis:16-3.4 | Out-Null

    $initComplete = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
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

    $ready = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
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

    docker exec -e PGPASSWORD=postgres $ContainerName createdb -U postgres $DatabaseName
    foreach ($migration in (Get-ChildItem -Path $migrationDir -Filter "*.sql" -File | Sort-Object Name)) {
        docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not copy migration $($migration.Name)."
        }
        docker exec -e PGPASSWORD=postgres $ContainerName `
            psql -v ON_ERROR_STOP=1 -U postgres -d $DatabaseName -f "/tmp/$($migration.Name)" `
            | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Migration failed: $($migration.Name)."
        }
    }

    Invoke-Psql -Sql @"
insert into regions (code, name, source) values ('11', 'Ile-de-France', 'fixture');
insert into departments (code, name, region_code, source) values ('75', 'Paris', '11', 'fixture');
insert into cities (insee_code, name, department_code, region_code, source)
select lpad((10000 + series.number)::text, 5, '0'), 'Commune ' || series.number, '75', '11', 'fixture'
from generate_series(1, 1002) as series(number);
"@ | Out-Null

    & $coordinateScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser "postgres" `
        -DatabasePassword "postgres" `
        -CitiesUrl (Join-Path $fixtureDir "coordinates-complete.json") `
        -Source "test-coordinate-source" `
        -SourceYear 2026

    Assert-SqlEquals `
        -Sql "select count(*) from cities where geom is not null;" `
        -Expected "1002" `
        -Message "The complete coordinate source should geocode every fixture commune"
    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-coordinate-source';" `
        -Expected "1" `
        -Message "The complete coordinate import should record one completed batch"

    $partialRejected = $false
    try {
        & $coordinateScript `
            -ContainerName $ContainerName `
            -DatabaseName $DatabaseName `
            -DatabaseUser "postgres" `
            -DatabasePassword "postgres" `
            -CitiesUrl (Join-Path $fixtureDir "coordinates-partial.json") `
            -Source "test-coordinate-source" `
            -SourceYear 2026
    }
    catch {
        $partialRejected = $true
    }

    if (-not $partialRejected) {
        throw "A partial coordinate source should be rejected."
    }
    Assert-SqlEquals `
        -Sql "select latitude::text || ',' || longitude::text from cities where insee_code = '10001';" `
        -Expected "46.000100,2.000100" `
        -Message "A rejected partial source must not change existing coordinates"
    Assert-SqlEquals `
        -Sql "select count(*) from import_batches where source_system = 'test-coordinate-source';" `
        -Expected "1" `
        -Message "A rejected partial source must not record a completed import batch"

    Write-Host "City coordinate import test passed."
}
finally {
    if (Test-Path -LiteralPath $fixtureDir) {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force
    }
    docker rm -f $ContainerName 2>$null | Out-Null
}
