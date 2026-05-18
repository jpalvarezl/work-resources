BeforeAll {
    # Dot-source the module under test
    . "$PSScriptRoot/../scripts/common.ps1"
}

Describe "Validation Patterns" {
    Context "ResourceNamePattern" {
        It "accepts valid resource names" {
            "myapi" | Should -Match $ResourceNamePattern
            "my-api" | Should -Match $ResourceNamePattern
            "Resource1" | Should -Match $ResourceNamePattern
            "a" | Should -Match $ResourceNamePattern
            "abc-def-123" | Should -Match $ResourceNamePattern
        }

        It "rejects names starting with a number" {
            "1resource" | Should -Not -Match $ResourceNamePattern
        }

        It "rejects names starting with a hyphen" {
            "-resource" | Should -Not -Match $ResourceNamePattern
        }

        It "rejects names with underscores" {
            "my_resource" | Should -Not -Match $ResourceNamePattern
        }

        It "rejects empty string" {
            "" | Should -Not -Match $ResourceNamePattern
        }
    }

    Context "EnvVarNamePattern" {
        It "accepts valid env var names" {
            "MY_API_KEY" | Should -Match $EnvVarNamePattern
            "apiKey" | Should -Match $EnvVarNamePattern
            "_PRIVATE" | Should -Match $EnvVarNamePattern
            "A" | Should -Match $EnvVarNamePattern
            "var123" | Should -Match $EnvVarNamePattern
        }

        It "rejects names starting with a number" {
            "1VAR" | Should -Not -Match $EnvVarNamePattern
        }

        It "rejects names with hyphens" {
            "MY-VAR" | Should -Not -Match $EnvVarNamePattern
        }

        It "rejects empty string" {
            "" | Should -Not -Match $EnvVarNamePattern
        }
    }
}

Describe "Get-ProjectRoot" {
    It "returns WORK_RESOURCES_ROOT when set and path exists" {
        $testDir = Join-Path $TestDrive "wr-root"
        New-Item -ItemType Directory -Path $testDir | Out-Null
        $env:WORK_RESOURCES_ROOT = $testDir

        $result = Get-ProjectRoot
        $result | Should -Be $testDir

        $env:WORK_RESOURCES_ROOT = $null
    }

    It "falls back to ScriptRoot parent when env var not set" {
        $env:WORK_RESOURCES_ROOT = $null
        $scriptsDir = Join-Path $TestDrive "project" "scripts"
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

        $result = Get-ProjectRoot -ScriptRoot $scriptsDir
        $result | Should -Be (Join-Path $TestDrive "project")
    }

    It "falls back to ScriptRoot when env var path does not exist" {
        $env:WORK_RESOURCES_ROOT = "C:\nonexistent\path\that\does\not\exist"
        $scriptsDir = Join-Path $TestDrive "project2" "scripts"
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

        $result = Get-ProjectRoot -ScriptRoot $scriptsDir
        $result | Should -Be (Join-Path $TestDrive "project2")

        $env:WORK_RESOURCES_ROOT = $null
    }

    It "throws when no env var and no ScriptRoot" {
        $env:WORK_RESOURCES_ROOT = $null
        { Get-ProjectRoot } | Should -Throw "*Cannot determine project root*"
    }
}

Describe "Get-EnvSettings" {
    BeforeEach {
        $projectDir = Join-Path $TestDrive "env-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
    }

    It "parses .env from project root" {
        $envContent = @"
VAULT_NAME=my-vault
RESOURCE_GROUP_NAME=my-rg
SUBSCRIPTION_ID=sub-123
"@
        Set-Content (Join-Path $projectDir ".env") -Value $envContent

        $result = Get-EnvSettings -ProjectRoot $projectDir
        $result.vaultName | Should -Be "my-vault"
        $result.resourceGroupName | Should -Be "my-rg"
        $result.subscriptionId | Should -Be "sub-123"
    }

    It "parses .env from config/ subdirectory (preferred)" {
        $configDir = Join-Path $projectDir "config"
        New-Item -ItemType Directory -Path $configDir | Out-Null

        # Put different values in root vs config to prove config/ wins
        Set-Content (Join-Path $projectDir ".env") -Value "VAULT_NAME=root-vault`nRESOURCE_GROUP_NAME=root-rg"
        Set-Content (Join-Path $configDir ".env") -Value "VAULT_NAME=config-vault`nRESOURCE_GROUP_NAME=config-rg"

        $result = Get-EnvSettings -ProjectRoot $projectDir
        $result.vaultName | Should -Be "config-vault"
        $result.resourceGroupName | Should -Be "config-rg"
    }

    It "skips comments and empty lines" {
        $envContent = @"
# This is a comment
VAULT_NAME=my-vault

# Another comment
RESOURCE_GROUP_NAME=my-rg
"@
        Set-Content (Join-Path $projectDir ".env") -Value $envContent

        $result = Get-EnvSettings -ProjectRoot $projectDir
        $result.vaultName | Should -Be "my-vault"
        $result.resourceGroupName | Should -Be "my-rg"
    }

    It "handles quoted values" {
        $envContent = @"
VAULT_NAME="quoted-vault"
RESOURCE_GROUP_NAME='quoted-rg'
"@
        Set-Content (Join-Path $projectDir ".env") -Value $envContent

        $result = Get-EnvSettings -ProjectRoot $projectDir
        $result.vaultName | Should -Be "quoted-vault"
        $result.resourceGroupName | Should -Be "quoted-rg"
    }

    It "allows empty SUBSCRIPTION_ID" {
        $envContent = @"
VAULT_NAME=my-vault
RESOURCE_GROUP_NAME=my-rg
SUBSCRIPTION_ID=
"@
        Set-Content (Join-Path $projectDir ".env") -Value $envContent

        $result = Get-EnvSettings -ProjectRoot $projectDir
        $result.subscriptionId | Should -BeNullOrEmpty
    }

    It "throws when VAULT_NAME is missing" {
        Set-Content (Join-Path $projectDir ".env") -Value "RESOURCE_GROUP_NAME=my-rg"
        { Get-EnvSettings -ProjectRoot $projectDir } | Should -Throw "*VAULT_NAME is required*"
    }

    It "throws when RESOURCE_GROUP_NAME is missing" {
        Set-Content (Join-Path $projectDir ".env") -Value "VAULT_NAME=my-vault"
        { Get-EnvSettings -ProjectRoot $projectDir } | Should -Throw "*RESOURCE_GROUP_NAME is required*"
    }

    It "throws when .env file does not exist" {
        { Get-EnvSettings -ProjectRoot $projectDir } | Should -Throw "*Configuration not found*"
    }
}

Describe "ConvertTo-ShellEscapedSingleQuoted" {
    Context "PowerShell escaping" {
        It "doubles single quotes" {
            ConvertTo-ShellEscapedSingleQuoted -Value "abc'def" -Shell "powershell" | Should -Be "abc''def"
        }

        It "leaves backslashes literal" {
            ConvertTo-ShellEscapedSingleQuoted -Value 'a\b' -Shell "powershell" | Should -Be 'a\b'
        }

        It "leaves `$ literal" {
            ConvertTo-ShellEscapedSingleQuoted -Value 'a$VAR' -Shell "powershell" | Should -Be 'a$VAR'
        }

        It "round-trips when wrapped in single quotes and evaluated" {
            $raw = "abc'def`"with\$pecial"
            $escaped = ConvertTo-ShellEscapedSingleQuoted -Value $raw -Shell "powershell"
            $expression = "'$escaped'"
            $evaluated = Invoke-Expression $expression
            $evaluated | Should -Be $raw
        }

        It "produces parseable output for values with single quotes (regression: '\'' bug)" {
            $raw = "abc'def"
            $escaped = ConvertTo-ShellEscapedSingleQuoted -Value $raw -Shell "powershell"
            $expression = "`$env:WR_TEST_VAR = '$escaped';"
            { Invoke-Expression $expression } | Should -Not -Throw
            $env:WR_TEST_VAR | Should -Be $raw
            Remove-Item Env:WR_TEST_VAR -ErrorAction SilentlyContinue
        }

        It "accepts empty string" {
            ConvertTo-ShellEscapedSingleQuoted -Value "" -Shell "powershell" | Should -Be ""
        }
    }

    Context "Bash/Zsh escaping" {
        It "uses '\\'' for single quotes (bash)" {
            ConvertTo-ShellEscapedSingleQuoted -Value "abc'def" -Shell "bash" | Should -Be "abc'\''def"
        }

        It "uses '\\'' for single quotes (zsh)" {
            ConvertTo-ShellEscapedSingleQuoted -Value "abc'def" -Shell "zsh" | Should -Be "abc'\''def"
        }

        It "leaves backslashes literal in bash single quotes" {
            ConvertTo-ShellEscapedSingleQuoted -Value 'a\b' -Shell "bash" | Should -Be 'a\b'
        }

        It "leaves `$ literal" {
            ConvertTo-ShellEscapedSingleQuoted -Value 'a$VAR' -Shell "bash" | Should -Be 'a$VAR'
        }
    }

    Context "Fish escaping" {
        It "backslash-escapes single quotes" {
            ConvertTo-ShellEscapedSingleQuoted -Value "abc'def" -Shell "fish" | Should -Be "abc\'def"
        }

        It "backslash-escapes backslashes" {
            ConvertTo-ShellEscapedSingleQuoted -Value 'a\b' -Shell "fish" | Should -Be 'a\\b'
        }

        It "escapes backslashes before quotes to avoid corruption" {
            # raw a\'b -> a\\\'b (each \ doubled, then ' becomes \')
            ConvertTo-ShellEscapedSingleQuoted -Value "a\'b" -Shell "fish" | Should -Be "a\\\'b"
        }
    }
}

Describe "Test-SecretsOfficerRole" {
    BeforeAll {
        # Mock az CLI calls to avoid real Azure interactions
        Mock az {
            param()
            # Default: return nothing
        }
    }

    It "returns false when not logged in" {
        Mock az { $null } -ParameterFilter { $args[0] -eq "account" -and $args[1] -eq "show" }

        $result = Test-SecretsOfficerRole -VaultName "test-vault" -ResourceGroupName "test-rg"
        $result | Should -BeFalse
    }

    It "returns false when vault not found" {
        Mock az {
            '{"user": {"name": "user@company.com"}}' 
        } -ParameterFilter { $args[0] -eq "account" -and $args[1] -eq "show" }

        Mock az { $null } -ParameterFilter { $args[0] -eq "keyvault" -and $args[1] -eq "show" }

        # Probe also fails since vault doesn't exist
        Mock az { $global:LASTEXITCODE = 1; $null } -ParameterFilter { $args[0] -eq "keyvault" -and $args[1] -eq "secret" -and $args[2] -eq "set" }

        $result = Test-SecretsOfficerRole -VaultName "test-vault" -ResourceGroupName "test-rg"
        $result | Should -BeFalse
    }

    It "returns true when user has Secrets Officer role" {
        Mock az {
            '{"user": {"name": "user@company.com"}}'
        } -ParameterFilter { $args[0] -eq "account" -and $args[1] -eq "show" }

        Mock az {
            "/subscriptions/sub-id/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/test-vault"
        } -ParameterFilter { $args[0] -eq "keyvault" -and $args[1] -eq "show" }

        Mock az {
            '["Key Vault Secrets Officer"]'
        } -ParameterFilter { $args[0] -eq "role" -and $args[1] -eq "assignment" }

        $result = Test-SecretsOfficerRole -VaultName "test-vault" -ResourceGroupName "test-rg"
        $result | Should -BeTrue
    }

    It "returns true when user has Key Vault Administrator role" {
        Mock az {
            '{"user": {"name": "user@company.com"}}'
        } -ParameterFilter { $args[0] -eq "account" -and $args[1] -eq "show" }

        Mock az {
            "/subscriptions/sub-id/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/test-vault"
        } -ParameterFilter { $args[0] -eq "keyvault" -and $args[1] -eq "show" }

        Mock az {
            '["Key Vault Administrator"]'
        } -ParameterFilter { $args[0] -eq "role" -and $args[1] -eq "assignment" }

        $result = Test-SecretsOfficerRole -VaultName "test-vault" -ResourceGroupName "test-rg"
        $result | Should -BeTrue
    }

    It "returns false when user only has Secrets User role" {
        Mock az {
            '{"user": {"name": "user@company.com"}}'
        } -ParameterFilter { $args[0] -eq "account" -and $args[1] -eq "show" }

        Mock az {
            "/subscriptions/sub-id/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/test-vault"
        } -ParameterFilter { $args[0] -eq "keyvault" -and $args[1] -eq "show" }

        Mock az {
            '["Key Vault Secrets User"]'
        } -ParameterFilter { $args[0] -eq "role" -and $args[1] -eq "assignment" }

        $result = Test-SecretsOfficerRole -VaultName "test-vault" -ResourceGroupName "test-rg"
        $result | Should -BeFalse
    }
}
