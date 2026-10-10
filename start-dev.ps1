[CmdletBinding()]
param(
    [int]$Port = 3000,

    # Vérifie explicitement les catalogues officiels et importe les
    # nouvelles versions si nécessaire.
    [switch]$RefreshData,

    # Permet de démarrer une DB fraîche sans télécharger les datasets.
    [switch]$SkipDataBootstrap,

    # N'ouvre pas automatiquement le navigateur.
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($RefreshData -and $SkipDataBootstrap) {
    throw "-RefreshData et -SkipDataBootstrap ne peuvent pas être utilisés ensemble."
}

$Root = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Get-Location).Path
}

Set-Location $Root


# ---------------------------------------------------------------------------
# Affichage
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)

    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)

    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)

    Write-Host "SKIP  $Message" -ForegroundColor DarkGray
}


# ---------------------------------------------------------------------------
# Commandes requises
# ---------------------------------------------------------------------------

function Assert-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$InstallHint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' est introuvable. $InstallHint"
    }
}

Assert-Command "node" "Installe Node.js puis relance ce script."
Assert-Command "docker" "Installe Docker Desktop puis relance ce script."

$NpmCommand = $null

if (Get-Command "npm.cmd" -ErrorAction SilentlyContinue) {
    $NpmCommand = "npm.cmd"
}
elseif (Get-Command "npm" -ErrorAction SilentlyContinue) {
    $NpmCommand = "npm"
}
else {
    throw "'npm' est introuvable. Vérifie ton installation Node.js."
}


# ---------------------------------------------------------------------------
# .env
# ---------------------------------------------------------------------------

function Import-DotEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line.StartsWith("#")) {
            continue
        }

        if ($line.StartsWith("export ")) {
            $line = $line.Substring(7).Trim()
        }

        $separator = $line.IndexOf("=")

        if ($separator -lt 1) {
            continue
        }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()

        if (
            $value.Length -ge 2 -and
            (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            )
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        [Environment]::SetEnvironmentVariable(
            $name,
            $value,
            [EnvironmentVariableTarget]::Process
        )
    }
}


Write-Step "Configuration de l'environnement"

$EnvPath = Join-Path $Root ".env"
$EnvExamplePath = Join-Path $Root ".env.example"

if (-not (Test-Path -LiteralPath $EnvPath)) {
    if (-not (Test-Path -LiteralPath $EnvExamplePath)) {
        throw "Ni .env ni .env.example n'existent."
    }

    Copy-Item -LiteralPath $EnvExamplePath -Destination $EnvPath

    Write-Ok ".env créé depuis .env.example"
}
else {
    Write-Skip ".env existe déjà"
}

Import-DotEnv -Path $EnvPath

$DatabaseName = if ([string]::IsNullOrWhiteSpace($env:POSTGRES_DB)) {
    "app_criminalite"
}
else {
    $env:POSTGRES_DB
}

$DatabaseUser = if ([string]::IsNullOrWhiteSpace($env:POSTGRES_USER)) {
    "app"
}
else {
    $env:POSTGRES_USER
}

$DatabasePassword = if ([string]::IsNullOrWhiteSpace($env:POSTGRES_PASSWORD)) {
    "app_dev_password"
}
else {
    $env:POSTGRES_PASSWORD
}

$DatabasePort = if ([string]::IsNullOrWhiteSpace($env:POSTGRES_PORT)) {
    "5432"
}
else {
    $env:POSTGRES_PORT
}

$ContainerName = "app-criminalite-db"

Write-Ok "Environnement chargé"


# ---------------------------------------------------------------------------
# Node / npm
# ---------------------------------------------------------------------------

Write-Step "Vérification de Node.js"

$NodeVersion = (& node --version).Trim()
$NpmVersion = (& $NpmCommand --version).Trim()

Write-Ok "Node.js $NodeVersion"
Write-Ok "npm $NpmVersion"


# ---------------------------------------------------------------------------
# Dépendances npm lazy
# ---------------------------------------------------------------------------

Write-Step "Vérification des dépendances npm"

$PackageLockPath = Join-Path $Root "package-lock.json"
$NodeModulesPath = Join-Path $Root "node_modules"

if (-not (Test-Path -LiteralPath $PackageLockPath)) {
    throw "package-lock.json est introuvable."
}

$LockHash = (Get-FileHash `
    -LiteralPath $PackageLockPath `
    -Algorithm SHA256
).Hash

$DependencyStampPath = Join-Path `
    $NodeModulesPath `
    ".weshsquive-package-lock.sha256"

$InstallDependencies = $false

if (-not (Test-Path -LiteralPath $NodeModulesPath)) {
    Write-Host "node_modules absent."
    $InstallDependencies = $true
}
elseif (Test-Path -LiteralPath $DependencyStampPath) {
    $PreviousHash = (
        Get-Content `
            -LiteralPath $DependencyStampPath `
            -Raw
    ).Trim()

    if ($PreviousHash -ne $LockHash) {
        Write-Host "package-lock.json a changé."
        $InstallDependencies = $true
    }
    else {
        Write-Skip "Dépendances npm déjà synchronisées"
    }
}
else {
    # Le projet peut avoir été installé avant l'existence du launcher.
    # npm ls permet d'éviter un npm ci inutile.
    & $NpmCommand ls --depth=0 *> $null

    if ($LASTEXITCODE -eq 0) {
        Set-Content `
            -LiteralPath $DependencyStampPath `
            -Value $LockHash `
            -NoNewline

        Write-Skip "node_modules déjà valide"
    }
    else {
        Write-Host "node_modules existe mais n'est pas cohérent."
        $InstallDependencies = $true
    }
}

if ($InstallDependencies) {
    Write-Host "Installation des dépendances..."

    & $NpmCommand ci

    if ($LASTEXITCODE -ne 0) {
        throw "npm ci a échoué."
    }

    Set-Content `
        -LiteralPath $DependencyStampPath `
        -Value $LockHash `
        -NoNewline

    Write-Ok "Dépendances npm installées"
}


# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

function Test-DockerReady {
    & docker info *> $null

    return ($LASTEXITCODE -eq 0)
}


Write-Step "Vérification de Docker"

& docker compose version *> $null

if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose v2 est introuvable."
}

if (-not (Test-DockerReady)) {
    Write-Host "Docker est installé mais le moteur n'est pas démarré."

    $DockerDesktopCandidates = @()

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $DockerDesktopCandidates += (
            Join-Path `
                $env:ProgramFiles `
                "Docker\Docker\Docker Desktop.exe"
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $DockerDesktopCandidates += (
            Join-Path `
                $env:LOCALAPPDATA `
                "Docker\Docker Desktop.exe"
        )
    }

    $DockerDesktop = $DockerDesktopCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if ($DockerDesktop) {
        Write-Host "Démarrage de Docker Desktop..."

        Start-Process `
            -FilePath $DockerDesktop `
            | Out-Null
    }
    else {
        throw "Docker n'est pas démarré et Docker Desktop n'a pas été trouvé."
    }

    $DockerReady = $false

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Seconds 2

        if (Test-DockerReady) {
            $DockerReady = $true
            break
        }
    }

    if (-not $DockerReady) {
        throw "Docker Desktop ne répond pas."
    }
}

Write-Ok "Docker disponible"


# ---------------------------------------------------------------------------
# PostgreSQL / PostGIS
# ---------------------------------------------------------------------------

Write-Step "Démarrage de PostgreSQL / PostGIS"

# docker compose est naturellement idempotent :
# - crée/pull au premier lancement ;
# - démarre si arrêté ;
# - ne recrée pas inutilement le conteneur s'il est déjà correct.
& docker compose up -d db

if ($LASTEXITCODE -ne 0) {
    throw "Impossible de démarrer le service PostgreSQL."
}

Write-Ok "Conteneur $ContainerName démarré"


# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------

Write-Step "Vérification des migrations"

$MigrationScript = Join-Path `
    $Root `
    "scripts\apply_migrations.ps1"

if (-not (Test-Path -LiteralPath $MigrationScript)) {
    throw "scripts/apply_migrations.ps1 est introuvable."
}

& $MigrationScript `
    -ContainerName $ContainerName `
    -DatabaseName $DatabaseName `
    -DatabaseUser $DatabaseUser `
    -DatabasePassword $DatabasePassword

Write-Ok "Schéma PostgreSQL à jour"


# ---------------------------------------------------------------------------
# Requêtes PostgreSQL simples
# ---------------------------------------------------------------------------

function Invoke-DatabaseScalar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $output = & docker exec `
        -e "PGPASSWORD=$DatabasePassword" `
        $ContainerName `
        psql `
        -q `
        -t `
        -A `
        -v ON_ERROR_STOP=1 `
        -U $DatabaseUser `
        -d $DatabaseName `
        -c $Sql

    if ($LASTEXITCODE -ne 0) {
        throw "La requête PostgreSQL de vérification a échoué."
    }

    return (($output -join "`n").Trim())
}


# ---------------------------------------------------------------------------
# Bootstrap / actualisation des données
# ---------------------------------------------------------------------------

Write-Step "Vérification des données applicatives"

$CoreDataState = Invoke-DatabaseScalar @"
select (
    exists(select 1 from cities limit 1)
    and exists(select 1 from population_history limit 1)
    and exists(select 1 from crime_stats limit 1)
)::text;
"@

$CoreDataReady = (
    $CoreDataState -eq "true" -or
    $CoreDataState -eq "t" -or
    $CoreDataState -eq "1"
)

$UpdateDataScript = Join-Path `
    $Root `
    "scripts\update_official_data.ps1"

if ($RefreshData) {
    if (-not (Test-Path -LiteralPath $UpdateDataScript)) {
        throw "scripts/update_official_data.ps1 est introuvable."
    }

    Write-Host "Recherche explicite de nouvelles données officielles..."

    & $UpdateDataScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser $DatabaseUser `
        -DatabasePassword $DatabasePassword

    Write-Ok "Vérification des données officielles terminée"
}
elseif (-not $CoreDataReady -and -not $SkipDataBootstrap) {
    if (-not (Test-Path -LiteralPath $UpdateDataScript)) {
        throw "scripts/update_official_data.ps1 est introuvable."
    }

    Write-Host "Base fraîche détectée."
    Write-Host "Import initial des données officielles..."

    & $UpdateDataScript `
        -ContainerName $ContainerName `
        -DatabaseName $DatabaseName `
        -DatabaseUser $DatabaseUser `
        -DatabasePassword $DatabasePassword

    Write-Ok "Données initiales importées"
}
elseif ($CoreDataReady) {
    Write-Skip "Données principales déjà présentes"
}
else {
    Write-Skip "Bootstrap des données désactivé"
}


# ---------------------------------------------------------------------------
# Port HTTP
# ---------------------------------------------------------------------------

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PortToTest
    )

    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        $result = $client.BeginConnect(
            "127.0.0.1",
            $PortToTest,
            $null,
            $null
        )

        if (-not $result.AsyncWaitHandle.WaitOne(200)) {
            return $false
        }

        $client.EndConnect($result)

        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}


function Test-WeshsquiveWebApp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $response = Invoke-WebRequest `
            -Uri $Url `
            -UseBasicParsing `
            -TimeoutSec 2

        return (
            $response.StatusCode -ge 200 -and
            $response.StatusCode -lt 400 -and
            $response.Content -match "App Criminalite"
        )
    }
    catch {
        return $false
    }
}


Write-Step "Sélection du port web"

$SelectedPort = $Port
$RequestedUrl = "http://localhost:$SelectedPort"

if (Test-TcpPort -PortToTest $SelectedPort) {
    if (Test-WeshsquiveWebApp -Url $RequestedUrl) {
        Write-Ok "Weshsquive tourne déjà sur $RequestedUrl"

        if (-not $NoBrowser) {
            Start-Process $RequestedUrl
        }

        return
    }

    Write-Host "Le port $SelectedPort est déjà utilisé par une autre application."

    $FreePortFound = $false

    for (
        $CandidatePort = $SelectedPort + 1;
        $CandidatePort -le $SelectedPort + 50;
        $CandidatePort++
    ) {
        if (-not (Test-TcpPort -PortToTest $CandidatePort)) {
            $SelectedPort = $CandidatePort
            $FreePortFound = $true
            break
        }
    }

    if (-not $FreePortFound) {
        throw "Impossible de trouver un port HTTP libre."
    }

    Write-Ok "Port $SelectedPort sélectionné"
}
else {
    Write-Ok "Port $SelectedPort disponible"
}


# ---------------------------------------------------------------------------
# Démarrage Next.js + ouverture automatique du navigateur
# ---------------------------------------------------------------------------

$Url = "http://localhost:$SelectedPort"

Write-Step "Démarrage de Weshsquive"

Write-Host "URL : $Url"
Write-Host ""
Write-Host "Ctrl+C pour arrêter le serveur."
Write-Host ""


$BrowserJob = $null

if (-not $NoBrowser) {
    # Le job attend que Next.js réponde réellement avant d'ouvrir le navigateur.
    $BrowserJob = Start-Job `
        -ArgumentList $Url `
        -ScriptBlock {
            param($TargetUrl)

            $ProgressPreference = "SilentlyContinue"

            for ($attempt = 0; $attempt -lt 120; $attempt++) {
                try {
                    $response = Invoke-WebRequest `
                        -Uri $TargetUrl `
                        -UseBasicParsing `
                        -TimeoutSec 2

                    if (
                        $response.StatusCode -ge 200 -and
                        $response.StatusCode -lt 400
                    ) {
                        Start-Process $TargetUrl
                        return
                    }
                }
                catch {
                    # Next.js n'est simplement pas encore prêt.
                }

                Start-Sleep -Milliseconds 500
            }
        }
}


try {
    & $NpmCommand run dev -- -p $SelectedPort

    if ($LASTEXITCODE -ne 0) {
        throw "Le serveur Next.js s'est arrêté avec le code $LASTEXITCODE."
    }
}
finally {
    if ($null -ne $BrowserJob) {
        Stop-Job `
            -Job $BrowserJob `
            -ErrorAction SilentlyContinue

        Remove-Job `
            -Job $BrowserJob `
            -Force `
            -ErrorAction SilentlyContinue
    }
}