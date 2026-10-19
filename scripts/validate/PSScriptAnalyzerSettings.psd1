@{
    # El bootstrap corre en Windows PowerShell 5.1 (y en 7 si existe): las reglas de
    # compatibilidad importan mas que el estilo.
    Severity     = @('Error', 'Warning')

    IncludeRules = @(
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseIdenticalMandatoryParametersForDSC',
        'PSUseConsistentIndentation',
        'PSUseConsistentWhitespace',
        'PSPossibleIncorrectComparisonWithNull',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingUserNameAndPassWordParams',
        'PSAvoidUsingPlainTextForPassword',
        'PSUsePSCredentialType',
        'PSAvoidTrailingWhitespace',
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        'PSProvideCommentHelp',
        'PSAvoidUsingWriteHost',
        'PSReservedCmdletChar',
        'PSReservedParams',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingWMICmdlet',
        'PSAvoidUsingComputerNameHardcoded',
        'PSUseToExportFieldsInManifest',
        'PSMissingModuleManifestField',
        'PSUseUTF8EncodingForHelpLabel'
    )

    Rules        = @{
        PSUseApprovedVerbs = @{
            # El proyecto usa Test-/Get-/Set- para todo lo que no es verbos estándar;
            # Install-* es estándar, asi que no hacen falta excepciones.
        }
        PSAvoidUsingWriteHost = @{
            # Se escribe en consola a proposito: son informes para humanos que ademas
            # se guardan en .md/.csv. Silenciarlo aqui; el validador del repo comprueba
            # que todo Write-Host vaya acompanado de su registro en fichero.
        }
        PSUseConsistentIndentation = @{
            Enable       = $true
            IndentationWidth = 4
        }
    }
}
