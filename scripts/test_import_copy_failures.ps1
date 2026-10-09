$ErrorActionPreference = "Stop"

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-copy-fixtures-$PID"
$script:MockDockerExecCount = 0

function docker {
    $dockerArguments = @($args)
    if ($dockerArguments[0] -eq "cp") {
        $global:LASTEXITCODE = 1
        return "simulated docker cp failure"
    }

    if ($dockerArguments[0] -eq "exec") {
        $script:MockDockerExecCount++
        $global:LASTEXITCODE = 0
        return
    }

    throw "Unexpected docker command in copy-failure test: $($dockerArguments -join ' ')"
}

function Assert-CopyFailureStopsImport {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $script:MockDockerExecCount = 0
    $failed = $false
    try {
        & $Action
    }
    catch {
        $failed = $true
    }

    if (-not $failed) {
        throw "$Name should fail when docker cp fails."
    }
    if ($script:MockDockerExecCount -ne 0) {
        throw "$Name must not invoke psql after a failed docker cp."
    }
}

try {
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

    @'
[{"code":"11","nom":"Ile-de-France"}]
'@ | Set-Content -Path (Join-Path $fixtureDir "regions.json") -Encoding utf8
    @'
[{"code":"75","nom":"Paris","codeRegion":"11"}]
'@ | Set-Content -Path (Join-Path $fixtureDir "departments.json") -Encoding utf8
    @'
[{"code":"75056","nom":"Paris","codeDepartement":"75","codeRegion":"11"}]
'@ | Set-Content -Path (Join-Path $fixtureDir "cities.json") -Encoding utf8

    @'
"GEO";"GEO_OBJECT";"FREQ";"POPREF_MEASURE";"TIME_PERIOD";"OBS_VALUE"
"75056";"COM";"A";"PMUN";2025;2200000
'@ | Set-Content -Path (Join-Path $fixtureDir "population.csv") -Encoding utf8

    @'
CODGEO_2027;annee;indicateur;unite_de_compte;nombre;taux_pour_mille;est_diffuse;insee_pop;insee_pop_millesime;insee_log;insee_log_millesime;complement_info_nombre;complement_info_taux
75056;2025;Cambriolages de logement;Infraction;4;8,0;diff;1044;2023;500;2023;NA;NA
'@ | Set-Content -Path (Join-Path $fixtureDir "crime.csv") -Encoding utf8

    $commonArguments = @{
        ContainerName = "copy-failure-test"
        DatabaseName = "test"
        DatabaseUser = "test"
        DatabasePassword = "test"
    }

    Assert-CopyFailureStopsImport -Name "Administrative import" -Action {
        & (Join-Path $PSScriptRoot "import_administrative_areas.ps1") @commonArguments `
            -RegionsUrl (Join-Path $fixtureDir "regions.json") `
            -DepartmentsUrl (Join-Path $fixtureDir "departments.json") `
            -CitiesUrl (Join-Path $fixtureDir "cities.json") `
            -DeferMetricsRefresh
    }

    Assert-CopyFailureStopsImport -Name "Population import" -Action {
        & (Join-Path $PSScriptRoot "import_population_insee.ps1") @commonArguments `
            -PopulationFileUrl (Join-Path $fixtureDir "population.csv") `
            -PopulationYear 2025 `
            -DeferMetricsRefresh
    }

    Assert-CopyFailureStopsImport -Name "SSMSI import" -Action {
        & (Join-Path $PSScriptRoot "import_crime_data_ssmsi.ps1") @commonArguments `
            -CrimeFileUrl (Join-Path $fixtureDir "crime.csv") `
            -Year 2025 `
            -GeographyYear 2027 `
            -DeferMetricsRefresh
    }

    Write-Host "Import copy-failure tests passed."
}
finally {
    if (Test-Path -LiteralPath $fixtureDir) {
        Remove-Item -LiteralPath $fixtureDir -Recurse -Force
    }
}
