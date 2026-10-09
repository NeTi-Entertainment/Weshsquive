param(
    [Parameter(Mandatory = $true)][ValidateRange(2000, 2100)][int]$Year,
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) { $DatabaseName = "app_criminalite" }
if ([string]::IsNullOrWhiteSpace($DatabaseUser)) { $DatabaseUser = "app" }
if ([string]::IsNullOrWhiteSpace($DatabasePassword)) { $DatabasePassword = "app_dev_password" }

$sqlPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "db/refresh_property_market_metrics.sql"
if (-not (Test-Path -LiteralPath $sqlPath -PathType Leaf)) {
    throw "Property market metrics refresh SQL was not found at $sqlPath"
}

$containerSqlPath = "/tmp/refresh-property-market-metrics.sql"
docker cp $sqlPath "${ContainerName}:$containerSqlPath"
if ($LASTEXITCODE -ne 0) { throw "Could not copy property market refresh SQL into '$ContainerName'." }

docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
    psql -v ON_ERROR_STOP=1 -v "year=$Year" -U $DatabaseUser -d $DatabaseName -f $containerSqlPath

if ($LASTEXITCODE -ne 0) {
    throw "Property market metrics refresh failed for $Year; existing committed metrics remain available."
}
