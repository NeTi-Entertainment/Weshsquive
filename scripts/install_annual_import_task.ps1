[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param([switch]$Remove)

$ErrorActionPreference = "Stop"
$taskName = "AppCriminalite - Imports officiels"

if (-not $IsWindows) {
    throw "The annual import task can only be configured on Windows."
}

if ($Remove) {
    if ($PSCmdlet.ShouldProcess($taskName, "Remove the monthly official-data check")) {
        & schtasks.exe /Delete /TN $taskName /F
        if ($LASTEXITCODE -ne 0) {
            throw "Could not remove scheduled task '$taskName'."
        }
        Write-Host "Removed scheduled task '$taskName'."
    }
    return
}

$updateScript = (Resolve-Path (Join-Path $PSScriptRoot "update_official_data.ps1")).Path
$powerShellExe = (Get-Process -Id $PID).Path
$taskAction = "`"$powerShellExe`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$updateScript`""
$arguments = @(
    "/Create",
    "/SC", "MONTHLY",
    "/D", "1",
    "/TN", $taskName,
    "/TR", $taskAction,
    "/ST", "08:00",
    "/RL", "LIMITED",
    "/IT",
    "/F"
)

if ($PSCmdlet.ShouldProcess($taskName, "Run a monthly check on day 1 at 08:00 while the current user is signed in")) {
    & schtasks.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create scheduled task '$taskName'."
    }
    Write-Host "Registered '$taskName'. It runs only while the current user is signed in."
}
