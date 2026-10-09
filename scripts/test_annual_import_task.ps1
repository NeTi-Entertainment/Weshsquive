$ErrorActionPreference = "Stop"

$installer = Join-Path $PSScriptRoot "install_annual_import_task.ps1"
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "The annual import task installer should be available."
}

function Test-TaskExists {
    & schtasks.exe /Query /TN "AppCriminalite - Imports officiels" *> $null
    return $LASTEXITCODE -eq 0
}

$beforeInstallPreview = Test-TaskExists
& $installer -WhatIf | Out-Null
if ((Test-TaskExists) -ne $beforeInstallPreview) {
    throw "WhatIf must not change whether the scheduled task exists."
}

$beforeRemovePreview = Test-TaskExists
& $installer -Remove -WhatIf | Out-Null
if ((Test-TaskExists) -ne $beforeRemovePreview) {
    throw "Remove with WhatIf must not change whether the scheduled task exists."
}

Write-Host "Annual import task test passed."
