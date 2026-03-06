Describe "Setup Role Determination Logic" {
    # This tests the role selection logic from setup.ps1:
    #   if ($Role -eq "Admin" -or (-not $Role -and -not $vaultExists)) -> Officer
    #   else -> User

    BeforeAll {
        function Get-RoleForSetup {
            param(
                [string]$Role,
                [bool]$VaultExists
            )
            if ($Role -eq "Admin" -or (-not $Role -and -not $VaultExists)) {
                return @{ AzureRole = "Key Vault Secrets Officer"; Label = "Admin (read + write)" }
            } else {
                return @{ AzureRole = "Key Vault Secrets User"; Label = "User (read-only)" }
            }
        }
    }

    Context "New vault (vault does not exist)" {
        It "defaults to Officer when no -Role specified" {
            $result = Get-RoleForSetup -Role "" -VaultExists $false
            $result.AzureRole | Should -Be "Key Vault Secrets Officer"
        }

        It "uses Officer when -Role Admin" {
            $result = Get-RoleForSetup -Role "Admin" -VaultExists $false
            $result.AzureRole | Should -Be "Key Vault Secrets Officer"
        }

        It "uses User when -Role User (even for new vault)" {
            $result = Get-RoleForSetup -Role "User" -VaultExists $false
            $result.AzureRole | Should -Be "Key Vault Secrets User"
        }
    }

    Context "Existing vault (joining a team vault)" {
        It "defaults to User when no -Role specified" {
            $result = Get-RoleForSetup -Role "" -VaultExists $true
            $result.AzureRole | Should -Be "Key Vault Secrets User"
        }

        It "uses Officer when -Role Admin" {
            $result = Get-RoleForSetup -Role "Admin" -VaultExists $true
            $result.AzureRole | Should -Be "Key Vault Secrets Officer"
        }

        It "uses User when -Role User" {
            $result = Get-RoleForSetup -Role "User" -VaultExists $true
            $result.AzureRole | Should -Be "Key Vault Secrets User"
        }
    }
}
