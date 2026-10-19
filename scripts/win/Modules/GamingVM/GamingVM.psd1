@{
    RootModule        = 'GamingVM.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8f4b6a1e-2d6c-4e57-9c1a-7c1f0b5d2a11'
    Author            = 'Win Gaming VM contributors'
    CompanyName       = 'Win Gaming VM'
    Copyright         = 'MIT (c) 2026'
    Description       = 'Funciones comunes del bootstrap de la VM de gaming con Windows: log, checkpoints, registro, winget, firmas, GPU, informes.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Initialize-GvmRuntime', 'Get-GvmPaths', 'Write-GvmLog',
        'Set-GvmCheckpoint', 'Get-GvmCheckpoint',
        'Test-GvmEsAdministrador', 'Assert-GvmAdministrador', 'Test-GvmRequisito',
        'Get-GvmConfig', 'Resolve-GvmConfig', 'Get-GvmConfigValor',
        'Set-GvmRegistryValue', 'Get-GvmRegistryValue',
        'Test-GvmOrigenPermitido',
        'Get-GvmGpuInfo', 'Test-GvmDirectXDisponible',
        'Get-GvmWingetComando', 'Install-GvmWingetApp', 'Get-GvmAppInstalada', 'Test-GvmFirma',
        'New-GvmInforme', 'New-GvmHallazgo',
        'Set-GvmTareaProgramada', 'Get-GvmSesionActual', 'Get-GvmCpuResumen',
        'ConvertTo-GvmLlano', 'ConvertTo-GvmJson'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('windows', 'gaming', 'rdp', 'vm', 'sunshine', 'winget')
            LicenseUri = 'https://github.com/lyanvalentinmail-prog/Win/blob/main/LICENSE'
            ProjectUri = 'https://github.com/lyanvalentinmail-prog/Win'
        }
    }
}
