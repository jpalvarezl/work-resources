Describe "Setup Role Determination Logic" {
    # Tests the Get-SetupRole function from common.ps1

    BeforeAll {
        . "$PSScriptRoot/../scripts/common.ps1"
    }

    Context "New vault (vault does not exist)" {
        It "defaults to Officer when no -Role specified" {
            $result = Get-SetupRole -Role "" -VaultExists $false
            $result.AzureRole | Should -Be "Key Vault Secrets Officer"
        }

        It "uses Officer when -Role Admin" {
            $result = Get-SetupRole -Role "Admin" -VaultExists $false
            $result.AzureRole | Should -Be "Key Vault Secrets Officer"
        }

        It "uses User when -Role User (even for new vault)" {
            $result = Get-SetupRole -Role "User" -VaultExists $false
            $result.AzureRole | Should -Be "Key Vault Secrets User"
        }
    }

    Context "Existing vault (joining a team vault)" {
        It "defaults to User when no -Role specified" {
            $result = Get-SetupRole -Role "" -VaultExists $true
            $result.AzureRole | Should -Be "Key Vault Secrets User"
        }

        It "uses Officer when -Role Admin" {
            $result = Get-SetupRole -Role "Admin" -VaultExists $true
            $result.AzureRole | Should -Be "Key Vault Secrets Officer"
        }

        It "uses User when -Role User" {
            $result = Get-SetupRole -Role "User" -VaultExists $true
            $result.AzureRole | Should -Be "Key Vault Secrets User"
        }
    }
}
