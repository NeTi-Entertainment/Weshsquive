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

$sqlPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "db/refresh_search_metrics.sql"
if (-not (Test-Path -LiteralPath $sqlPath -PathType Leaf)) {
    throw "Search metrics refresh SQL was not found at $sqlPath"
}

$containerSqlPath = "/tmp/refresh-search-metrics.sql"
docker cp $sqlPath "${ContainerName}:$containerSqlPath"
if ($LASTEXITCODE -ne 0) {
    throw "Could not copy search metrics refresh SQL into '$ContainerName'."
}

docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
    psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -f $containerSqlPath

if ($LASTEXITCODE -ne 0) {
    throw "Search metrics refresh failed. The previously active snapshot remains available; rerun scripts/refresh_search_metrics.ps1 after resolving the database error."
}
