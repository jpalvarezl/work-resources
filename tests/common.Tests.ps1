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

    Context "FlavorNamePattern" {
        # Use -CMatch (case-sensitive) throughout. [ValidatePattern] is
        # case-sensitive by default at runtime, and the flavor convention is
        # strictly lowercase — we want the test to fail if either changes.
        It "accepts common flavor names" {
            "base"     | Should -CMatch $FlavorNamePattern
            "superset" | Should -CMatch $FlavorNamePattern
            "py"       | Should -CMatch $FlavorNamePattern
            "js"       | Should -CMatch $FlavorNamePattern
            "net"      | Should -CMatch $FlavorNamePattern
            "java"     | Should -CMatch $FlavorNamePattern
        }

        It "accepts hyphenated and digit-containing flavors" {
            "unit-test" | Should -CMatch $FlavorNamePattern
            "node-20"   | Should -CMatch $FlavorNamePattern
            "e2e"       | Should -CMatch $FlavorNamePattern
        }

        It "accepts a single letter" {
            "a" | Should -CMatch $FlavorNamePattern
        }

        It "rejects uppercase" {
            "PY"   | Should -Not -CMatch $FlavorNamePattern
            "Java" | Should -Not -CMatch $FlavorNamePattern
        }

        It "rejects names starting with a digit or hyphen" {
            "1node" | Should -Not -CMatch $FlavorNamePattern
            "-py"   | Should -Not -CMatch $FlavorNamePattern
        }

        It "rejects names ending with a hyphen" {
            "py-"      | Should -Not -CMatch $FlavorNamePattern
            "node-20-" | Should -Not -CMatch $FlavorNamePattern
        }

        It "rejects underscores and other punctuation" {
            "unit_test" | Should -Not -CMatch $FlavorNamePattern
            "py.env"    | Should -Not -CMatch $FlavorNamePattern
        }

        It "rejects empty string" {
            "" | Should -Not -CMatch $FlavorNamePattern
        }

        It "is case-sensitive when used by PowerShell's case-insensitive matchers (regression: (?-i) modifier present)" {
            # PowerShell's -match and [ValidatePattern] attribute are
            # case-insensitive by default. The pattern must embed (?-i)
            # so callers can't sneak uppercase through.
            "PY" | Should -Not -Match $FlavorNamePattern
            "py" | Should -Match $FlavorNamePattern
        }

        It "[ValidatePattern] using FlavorNamePattern rejects uppercase at param binding" {
            # Bake the constant into a literal pattern attribute so this also
            # acts as a regression guard against the attribute being weakened.
            function Test-FlavorParam {
                param(
                    [ValidatePattern('(?-i)^[a-z]([a-z0-9-]*[a-z0-9])?$')]
                    [string]$Flavor
                )
                $Flavor
            }
            { Test-FlavorParam -Flavor "PY" }   | Should -Throw
            { Test-FlavorParam -Flavor "Java" } | Should -Throw
            { Test-FlavorParam -Flavor "py" }   | Should -Not -Throw
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

Describe "Test-SecretTagsMatchFilter" {
    BeforeAll {
        function New-Tags {
            param([string]$Resource, [string]$Flavor, [string]$EnvVarName)
            $obj = [pscustomobject]@{}
            if ($PSBoundParameters.ContainsKey('Resource')) {
                $obj | Add-Member -NotePropertyName 'resource' -NotePropertyValue $Resource
            }
            if ($PSBoundParameters.ContainsKey('Flavor')) {
                $obj | Add-Member -NotePropertyName 'flavor' -NotePropertyValue $Flavor
            }
            if ($PSBoundParameters.ContainsKey('EnvVarName')) {
                $obj | Add-Member -NotePropertyName 'env-var-name' -NotePropertyValue $EnvVarName
            }
            return $obj
        }
    }

    Context "no filters" {
        It "matches a fully-tagged secret" {
            $t = New-Tags -Resource "r" -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t | Should -BeTrue
        }

        It "matches a secret with no tags at all" {
            Test-SecretTagsMatchFilter -Tags $null | Should -BeTrue
        }

        It "matches an unflavored legacy secret" {
            $t = New-Tags -Resource "r"
            Test-SecretTagsMatchFilter -Tags $t | Should -BeTrue
        }
    }

    Context "resource filter only" {
        It "matches when secret resource is in the filter list" {
            $t = New-Tags -Resource "myapp" -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t -ResourceFilters @("myapp","other") | Should -BeTrue
        }

        It "rejects when secret resource is not in the filter list" {
            $t = New-Tags -Resource "wrong" -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t -ResourceFilters @("myapp") | Should -BeFalse
        }

        It "rejects a secret with no resource tag when resource filter is set" {
            $t = New-Tags -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t -ResourceFilters @("myapp") | Should -BeFalse
        }

        It "rejects a secret with empty resource tag" {
            $t = New-Tags -Resource "" -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t -ResourceFilters @("myapp") | Should -BeFalse
        }

        It "rejects null tags when resource filter is set" {
            Test-SecretTagsMatchFilter -Tags $null -ResourceFilters @("myapp") | Should -BeFalse
        }
    }

    Context "flavor filter only" {
        It "matches when secret flavor is in the filter list" {
            $t = New-Tags -Resource "r" -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t -FlavorFilters @("py") | Should -BeTrue
        }

        It "matches with multi-flavor filter" {
            $t = New-Tags -Resource "r" -Flavor "js"
            Test-SecretTagsMatchFilter -Tags $t -FlavorFilters @("py","js","net") | Should -BeTrue
        }

        It "rejects when flavor differs" {
            $t = New-Tags -Resource "r" -Flavor "java"
            Test-SecretTagsMatchFilter -Tags $t -FlavorFilters @("py") | Should -BeFalse
        }

        It "rejects unflavored legacy secret when flavor filter set (no implicit match)" {
            $t = New-Tags -Resource "r"
            Test-SecretTagsMatchFilter -Tags $t -FlavorFilters @("py") | Should -BeFalse
        }
    }

    Context "combined filters" {
        It "requires both resource AND flavor to match" {
            $t = New-Tags -Resource "myapp" -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t -ResourceFilters @("myapp") -FlavorFilters @("py") | Should -BeTrue
        }

        It "rejects when resource matches but flavor does not" {
            $t = New-Tags -Resource "myapp" -Flavor "js"
            Test-SecretTagsMatchFilter -Tags $t -ResourceFilters @("myapp") -FlavorFilters @("py") | Should -BeFalse
        }

        It "rejects when flavor matches but resource does not" {
            $t = New-Tags -Resource "other" -Flavor "py"
            Test-SecretTagsMatchFilter -Tags $t -ResourceFilters @("myapp") -FlavorFilters @("py") | Should -BeFalse
        }
    }
}

Describe "Resolve-NameFilter" {
    Context "when -Name is empty / null" {
        It "returns null with no filters" {
            Resolve-NameFilter -Name "" -ResourceFilters @() -FlavorFilters @() | Should -BeNullOrEmpty
        }
        It "returns null even when Resource and Flavor are supplied" {
            Resolve-NameFilter -Name "" -ResourceFilters @("r") -FlavorFilters @("py") | Should -BeNullOrEmpty
        }
        It "returns null for whitespace-only Name" {
            Resolve-NameFilter -Name "   " -ResourceFilters @("r") | Should -BeNullOrEmpty
        }
    }

    Context "ValidatePattern in the consuming scripts accepts empty -Name" {
        # Regression: a wrapper that splats $Name="" must behave like no -Name.
        # The script-level [ValidatePattern] must allow empty string at param
        # binding so Resolve-NameFilter can treat it as 'no filter'.
        It "accepts empty string at param binding" {
            function Test-NameParam {
                param(
                    [ValidatePattern('^([a-zA-Z][a-zA-Z0-9-]*)?$')]
                    [string]$Name
                )
                $Name
            }
            { Test-NameParam -Name "" }    | Should -Not -Throw
            { Test-NameParam -Name "foo" } | Should -Not -Throw
            { Test-NameParam -Name "1bad" }| Should -Throw
            { Test-NameParam -Name "u_s" } | Should -Throw
        }
    }

    Context "when -Name is set" {
        It "composes {Resource}-{Name} when no flavor supplied" {
            Resolve-NameFilter -Name "endpoint" -ResourceFilters @("myapi") | Should -Be "myapi-endpoint"
        }
        It "composes {Resource}-{Flavor}-{Name} when single flavor supplied" {
            Resolve-NameFilter -Name "endpoint" -ResourceFilters @("myapi") -FlavorFilters @("py") | Should -Be "myapi-py-endpoint"
        }
        It "throws when no Resource is supplied" {
            { Resolve-NameFilter -Name "endpoint" -ResourceFilters @() -FlavorFilters @() } | Should -Throw "*requires -Resource*"
        }
        It "throws when multiple Resources are supplied" {
            { Resolve-NameFilter -Name "endpoint" -ResourceFilters @("r1","r2") } | Should -Throw "*single -Resource*"
        }
        It "throws when multiple Flavors are supplied" {
            { Resolve-NameFilter -Name "endpoint" -ResourceFilters @("r") -FlavorFilters @("py","js") } | Should -Throw "*at most one -Flavor*"
        }
    }
}

Describe "Write-EnvFileBlock and Remove-EnvFileBlock" {
    BeforeEach {
        $script:envFile = Join-Path $TestDrive "env-test-$(Get-Random).env"
    }

    Context "Write-EnvFileBlock" {
        It "creates the file when missing, with a sorted fenced block" {
            Write-EnvFileBlock -Path $envFile -Values @{ B = 'two'; A = 'one' }
            Test-Path $envFile | Should -BeTrue
            $content = Get-Content $envFile -Raw
            $content | Should -BeLike "*# >>> work-resources >>>*"
            $content | Should -BeLike "*# <<< work-resources <<<*"
            # A must appear before B (sorted)
            $idxA = $content.IndexOf("A='one'")
            $idxB = $content.IndexOf("B='two'")
            $idxA | Should -BeGreaterThan -1
            $idxB | Should -BeGreaterThan $idxA
        }

        It "creates parent directory if missing" {
            $nested = Join-Path $TestDrive "deep/sub/.env"
            Write-EnvFileBlock -Path $nested -Values @{ X = 'y' }
            Test-Path $nested | Should -BeTrue
        }

        It "appends a fenced block to an existing non-wr .env preserving user content" {
            $userContent = "USER_VAR=keep_me`nANOTHER=keep_too"
            Set-Content -Path $envFile -Value $userContent -NoNewline -Encoding utf8

            Write-EnvFileBlock -Path $envFile -Values @{ NEW = 'value' }

            $content = Get-Content $envFile -Raw
            $content | Should -BeLike "*USER_VAR=keep_me*"
            $content | Should -BeLike "*ANOTHER=keep_too*"
            $content | Should -BeLike "*NEW='value'*"
            # User content must come first; block appended at the end
            $content.IndexOf("USER_VAR") | Should -BeLessThan $content.IndexOf("# >>> work-resources >>>")
        }

        It "replaces the fenced block on a second call, preserving outside content" {
            Set-Content -Path $envFile -Value "USER_VAR=keep_me`n" -NoNewline -Encoding utf8
            Write-EnvFileBlock -Path $envFile -Values @{ FIRST = 'one' }
            Write-EnvFileBlock -Path $envFile -Values @{ SECOND = 'two' }

            $content = Get-Content $envFile -Raw
            $content | Should -BeLike "*USER_VAR=keep_me*"
            $content | Should -Not -BeLike "*FIRST=*"
            $content | Should -BeLike "*SECOND='two'*"
            # Only one fenced block
            ([regex]::Matches($content, [regex]::Escape("# >>> work-resources >>>"))).Count | Should -Be 1
        }

        It "round-trips values containing single quotes" {
            Write-EnvFileBlock -Path $envFile -Values @{ TRICKY = "a'b'c" }
            $content = Get-Content $envFile -Raw
            # POSIX close-escape-reopen form
            $content | Should -BeLike "*TRICKY='a'\''b'\''c'*"
        }

        It "round-trips values containing backslashes and dollar signs" {
            Write-EnvFileBlock -Path $envFile -Values @{ V = 'a\b$c' }
            $content = Get-Content $envFile -Raw
            # Inside POSIX single quotes, \ and $ are literal — no escaping needed
            $content | Should -BeLike "*V='a\b`$c'*"
        }

        It "round-trips values containing equals signs" {
            Write-EnvFileBlock -Path $envFile -Values @{ EQ = 'left=right' }
            $content = Get-Content $envFile -Raw
            $content | Should -BeLike "*EQ='left=right'*"
        }
    }

    Context "Remove-EnvFileBlock" {
        It "removes the fenced block leaving outside content untouched" {
            Set-Content -Path $envFile -Value "USER_VAR=keep_me`n" -NoNewline -Encoding utf8
            Write-EnvFileBlock -Path $envFile -Values @{ TEMP = 'gone' }
            $removed = Remove-EnvFileBlock -Path $envFile
            $removed | Should -BeTrue

            $content = Get-Content $envFile -Raw
            $content | Should -BeLike "*USER_VAR=keep_me*"
            $content | Should -Not -BeLike "*# >>> work-resources >>>*"
            $content | Should -Not -BeLike "*TEMP=*"
        }

        It "returns false and is a no-op when no block exists in file" {
            Set-Content -Path $envFile -Value "USER_VAR=keep_me`n" -NoNewline -Encoding utf8
            $removed = Remove-EnvFileBlock -Path $envFile
            $removed | Should -BeFalse
            (Get-Content $envFile -Raw) | Should -Be "USER_VAR=keep_me`n"
        }

        It "returns false when the file does not exist" {
            $removed = Remove-EnvFileBlock -Path (Join-Path $TestDrive "nonexistent.env")
            $removed | Should -BeFalse
        }

        It "deletes the file entirely when removing the block would leave it empty" {
            Write-EnvFileBlock -Path $envFile -Values @{ ONLY = 'one' }
            $removed = Remove-EnvFileBlock -Path $envFile
            $removed | Should -BeTrue
            Test-Path $envFile | Should -BeFalse
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
