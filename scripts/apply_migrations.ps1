param(
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
    $DatabaseName = "app_criminalite"
}

if ([string]::IsNullOrWhiteSpace($DatabaseUser)) {
    $DatabaseUser = "app"
}

if ([string]::IsNullOrWhiteSpace($DatabasePassword)) {
    $DatabasePassword = "app_dev_password"
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$migrationDir = Join-Path $root "db/migrations"
$migrationFiles = Get-ChildItem -Path $migrationDir -Filter "*.sql" -File | Sort-Object Name

if ($migrationFiles.Count -eq 0) {
    throw "No SQL migrations found in $migrationDir"
}

$databaseReady = $false

for ($attempt = 1; $attempt -le 60; $attempt++) {
    docker exec $ContainerName pg_isready -U $DatabaseUser -d $DatabaseName *> $null

    if ($LASTEXITCODE -eq 0) {
        $databaseReady = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $databaseReady) {
    throw "Database container '$ContainerName' did not become ready within 60 seconds."
}

docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
    psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c "create table if not exists schema_migrations (migration_name text primary key, applied_at timestamptz not null default now());" `
    | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Could not initialize migration tracking."
}

$legacyViewCount = docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
    psql -t -A -U $DatabaseUser -d $DatabaseName -c "select count(*) from pg_class where relname in ('city_year_category_metrics','city_year_comparative_metrics') and relkind = 'v';"

if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect existing database migrations."
}

$trackedMigrationCount = docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
    psql -t -A -U $DatabaseUser -d $DatabaseName -c "select count(*) from schema_migrations;"

if ($LASTEXITCODE -ne 0) {
    throw "Could not read migration tracking."
}

if ($trackedMigrationCount.Trim() -eq "0" -and $legacyViewCount.Trim() -eq "2") {
    docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c "insert into schema_migrations (migration_name) values ('001_initial_postgis_schema.sql'), ('002_comparative_index_views.sql') on conflict do nothing;" `
        | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Could not record the legacy schema baseline."
    }
}

foreach ($migration in $migrationFiles) {
    $isApplied = docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -t -A -U $DatabaseUser -d $DatabaseName -c "select exists (select 1 from schema_migrations where migration_name = '$($migration.Name)');"

    if ($LASTEXITCODE -ne 0) {
        throw "Could not check migration '$($migration.Name)'."
    }

    if ($isApplied.Trim() -eq "t") {
        Write-Host "Skipping $($migration.Name) (already applied)."
        continue
    }

    Write-Host "Applying $($migration.Name)..."
    docker cp $migration.FullName "${ContainerName}:/tmp/$($migration.Name)"

    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy migration '$($migration.Name)' into '$ContainerName'."
    }

    docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -f "/tmp/$($migration.Name)"

    if ($LASTEXITCODE -ne 0) {
        throw "Migration '$($migration.Name)' failed."
    }

    docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -c "insert into schema_migrations (migration_name) values ('$($migration.Name)');" `
        | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Could not record migration '$($migration.Name)'."
    }
}

$activeSnapshot = docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
    psql -t -A -U $DatabaseUser -d $DatabaseName -c "select exists (select 1 from search_metrics_active where singleton);"

if ($LASTEXITCODE -ne 0) {
    throw "Could not check the initial search metrics snapshot."
}

if ($activeSnapshot.Trim() -ne "t") {
    Write-Host "Building the initial search metrics snapshot..."
    & (Join-Path $PSScriptRoot "refresh_search_metrics.ps1") `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser $DatabaseUser `
        -DatabasePassword $DatabasePassword
}

$propertyMetricYears = docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
    psql -t -A -U $DatabaseUser -d $DatabaseName -c "select distinct source_year from (select source_year from property_sale_observations union select source_year from property_rent_observations) years where not exists (select 1 from property_market_metrics metrics where metrics.year = years.source_year) order by source_year;"

if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect property market metric years."
}

foreach ($propertyMetricYear in @($propertyMetricYears)) {
    if ([string]::IsNullOrWhiteSpace($propertyMetricYear)) { continue }
    Write-Host "Building property market metrics for $propertyMetricYear..."
    & (Join-Path $PSScriptRoot "refresh_property_market_metrics.ps1") `
        -Year ([int]$propertyMetricYear) `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser $DatabaseUser `
        -DatabasePassword $DatabasePassword
}

Write-Host "Migrations applied."
