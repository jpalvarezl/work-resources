# Shared helper functions for KeyVault scripts
# This file is dot-sourced by other scripts

# Validation patterns - used across multiple scripts
$script:ResourceNamePattern = '^[a-zA-Z][a-zA-Z0-9-]*$'
$script:EnvVarNamePattern = '^[A-Za-z_][A-Za-z0-9_]*$'
# Flavor names map to env-file suffixes (e.g. base, superset, py, js, net, java).
# Lowercase, must start with a letter, may include digits and internal hyphens,
# must not end with a hyphen so composed secret names never produce '--'.
# `(?-i)` makes the regex case-sensitive even when used with PowerShell's
# `-match` operator and the [ValidatePattern] attribute (both case-insensitive
# by default).
$script:FlavorNamePattern = '(?-i)^[a-z]([a-z0-9-]*[a-z0-9])?$'

function Test-SecretTagsMatchFilter {
    <#
    .SYNOPSIS
        Checks whether a secret's tags match the requested resource/flavor filters.
    .DESCRIPTION
        Returns $true when:
        - No resource filter is specified, or the secret's 'resource' tag exactly
          matches one of the requested resources.
        - AND no flavor filter is specified, or the secret's 'flavor' tag exactly
          matches one of the requested flavors.

        Secrets without a 'resource' tag never match a non-empty resource filter.
        Secrets without a 'flavor' tag never match a non-empty flavor filter
        (legacy secrets created before the flavor convention are excluded when
        callers explicitly ask for a flavor).
    .PARAMETER Tags
        The secret's tags object as returned by 'az keyvault secret list/show'
        (may be $null for an untagged secret).
    .PARAMETER ResourceFilters
        Optional array of resource names to require. Empty array = no filter.
    .PARAMETER FlavorFilters
        Optional array of flavor names to require. Empty array = no filter.
    #>
    param(
        [psobject]$Tags,

        [string[]]$ResourceFilters = @(),

        [string[]]$FlavorFilters = @()
    )

    if ($ResourceFilters.Count -gt 0) {
        $secretResource = if ($Tags) { $Tags.resource } else { $null }
        if ([string]::IsNullOrWhiteSpace($secretResource) -or $secretResource -notin $ResourceFilters) {
            return $false
        }
    }

    if ($FlavorFilters.Count -gt 0) {
        $secretFlavor = if ($Tags) { $Tags.flavor } else { $null }
        if ([string]::IsNullOrWhiteSpace($secretFlavor) -or $secretFlavor -notin $FlavorFilters) {
            return $false
        }
    }

    return $true
}

function Resolve-NameFilter {
    <#
    .SYNOPSIS
        Validates `-Name` filter constraints and returns the composed KV secret name to match.
    .DESCRIPTION
        Used by wr-load / wr-list / wr-clear when narrowing to a single secret.

        Rules:
        - If no `-Name` was supplied, returns $null (caller skips name filtering).
        - `-Name` requires `-Resource`. Multi-resource and multi-flavor filters are
          rejected because the composed name match would otherwise be ambiguous.

        Returns the exact KV secret name a candidate must equal:
        - `{Resource}-{Name}`           when no flavor was supplied
        - `{Resource}-{Flavor}-{Name}`  when a flavor was supplied
    #>
    param(
        [AllowEmptyString()]
        [string]$Name,

        [string[]]$ResourceFilters = @(),

        [string[]]$FlavorFilters = @()
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($ResourceFilters.Count -eq 0) {
        throw "-Name requires -Resource so the composed secret name is unambiguous."
    }
    if ($ResourceFilters.Count -gt 1) {
        throw "-Name requires a single -Resource (got: $($ResourceFilters -join ', '))."
    }
    if ($FlavorFilters.Count -gt 1) {
        throw "-Name requires at most one -Flavor (got: $($FlavorFilters -join ', '))."
    }

    $resourceName = $ResourceFilters[0]
    if ($FlavorFilters.Count -eq 1) {
        return "$resourceName-$($FlavorFilters[0])-$Name"
    }
    return "$resourceName-$Name"
}

function ConvertTo-ShellEscapedSingleQuoted {
    <#
    .SYNOPSIS
        Escapes a value for embedding inside a single-quoted string in the target shell.
    .DESCRIPTION
        Returns the escaped inner content WITHOUT surrounding quotes. The caller
        wraps with single quotes appropriate for the shell.

        Each shell has different escape rules for single-quoted strings:
        - bash/zsh (POSIX): no escapes are honored; close quote, insert escaped quote, reopen ('\'')
        - fish: backslash escapes for \ and ' (other chars are literal)
        - powershell: a single quote is escaped by doubling it ('')
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet("fish", "bash", "zsh", "powershell")]
        [string]$Shell
    )

    switch ($Shell) {
        "powershell" {
            return $Value -replace "'", "''"
        }
        "fish" {
            # Replace backslashes first so they don't double-escape the inserted \'
            $escaped = $Value -replace '\\', '\\'
            return $escaped -replace "'", "\'"
        }
        default {
            # bash / zsh
            return $Value -replace "'", "'\''"
        }
    }
}

# Marker comments that bracket the wr-managed block inside a user's .env file.
# These are intentionally distinctive — the chance of a hand-written `.env`
# already containing this exact string is essentially zero.
$script:EnvFileBlockStart = '# >>> work-resources >>>'
$script:EnvFileBlockEnd   = '# <<< work-resources <<<'

function Write-EnvFileBlock {
    <#
    .SYNOPSIS
        Writes (or replaces) the work-resources block inside a dotenv file.
    .DESCRIPTION
        Owns the disk-side of the wr-load -> .env handoff. Given a hashtable
        of {KEY=value}, emits a fenced block that looks like:

            # >>> work-resources >>>
            FOO='bar'
            QUUX='baz'
            # <<< work-resources <<<

        Existing content OUTSIDE the fences is preserved verbatim. If a fenced
        block already exists, it is REPLACED with the new content (so repeated
        wr-load calls do not accumulate stale entries). If no block exists,
        one is appended to the end of the file. If the file does not exist,
        it is created with just the fenced block.

        Values are emitted as POSIX single-quoted strings using the existing
        ConvertTo-ShellEscapedSingleQuoted helper. Keys are sorted ascending
        for determinism.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    # Build the new fenced block content
    $lines = @()
    $lines += $script:EnvFileBlockStart
    foreach ($key in ($Values.Keys | Sort-Object)) {
        $escaped = ConvertTo-ShellEscapedSingleQuoted -Value $Values[$key] -Shell 'bash'
        $lines += "$key='$escaped'"
    }
    $lines += $script:EnvFileBlockEnd
    $newBlock = $lines -join "`n"

    if (-not (Test-Path $Path)) {
        # Brand-new file: ensure parent dir exists, then just emit the block.
        $parent = Split-Path $Path -Parent
        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        # End with a trailing newline so editors / loaders are happy.
        Set-Content -Path $Path -Value ($newBlock + "`n") -NoNewline -Encoding utf8
        return
    }

    $existing = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $existing) { $existing = '' }

    # Replace an existing fenced block in place. The (?s) flag makes . match
    # newlines so we can span the whole block in one match. Both fences are
    # regex-escaped because they contain '>'.
    $startEsc = [regex]::Escape($script:EnvFileBlockStart)
    $endEsc   = [regex]::Escape($script:EnvFileBlockEnd)
    $pattern  = "(?s)$startEsc.*?$endEsc"

    if ([regex]::IsMatch($existing, $pattern)) {
        # In-place replacement preserves everything outside the fences.
        # Use a MatchEvaluator so `$` and `\` in $newBlock aren't treated as
        # substitution tokens by Regex.Replace.
        $updated = [regex]::Replace($existing, $pattern, { param($m) $newBlock })
        Set-Content -Path $Path -Value $updated -NoNewline -Encoding utf8
        return
    }

    # No existing block: append, separated by a blank line if the file is
    # non-empty so the block stands out from surrounding content.
    $separator = ''
    if ($existing.Length -gt 0) {
        if (-not $existing.EndsWith("`n")) { $separator = "`n" }
        $separator += "`n"
    }
    $updated = $existing + $separator + $newBlock + "`n"
    Set-Content -Path $Path -Value $updated -NoNewline -Encoding utf8
}

function Remove-EnvFileBlock {
    <#
    .SYNOPSIS
        Removes the work-resources block from a dotenv file.
    .DESCRIPTION
        The inverse of Write-EnvFileBlock. Strips the fenced block (and its
        fences) while leaving content outside the fences untouched. No-op if
        the file does not exist or contains no fenced block.

        Returns $true when a block was removed, $false otherwise. The boolean
        lets callers decide whether to print a "removed" status line.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $existing = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $existing -or $existing.Length -eq 0) {
        return $false
    }

    $startEsc = [regex]::Escape($script:EnvFileBlockStart)
    $endEsc   = [regex]::Escape($script:EnvFileBlockEnd)
    # Also eat one trailing newline so removing the block doesn't leave
    # a stray blank line. (?s) so . matches newlines inside the fences.
    $pattern  = "(?s)$startEsc.*?$endEsc`r?`n?"

    if (-not [regex]::IsMatch($existing, $pattern)) {
        return $false
    }

    $updated = [regex]::Replace($existing, $pattern, '')
    # Collapse runs of 3+ blank lines that may have resulted to at most 2.
    $updated = [regex]::Replace($updated, "(`r?`n){3,}", "`n`n")

    if ($updated.Length -eq 0) {
        # File would be empty — remove it entirely to avoid leaving a stub.
        Remove-Item -Path $Path -Force
    } else {
        Set-Content -Path $Path -Value $updated -NoNewline -Encoding utf8
    }
    return $true
}

function Get-ProjectRoot {
    <#
    .SYNOPSIS
        Resolves the project root directory.
    .DESCRIPTION
        Checks WORK_RESOURCES_ROOT environment variable first,
        then falls back to deriving from script location.
    #>
    param(
        [string]$ScriptRoot = $null
    )
    
    # First, check environment variable
    if ($env:WORK_RESOURCES_ROOT) {
        $root = $env:WORK_RESOURCES_ROOT
        if (Test-Path $root) {
            return $root
        }
        Write-Warning "WORK_RESOURCES_ROOT is set to '$root' but path does not exist. Falling back to script location."
    }
    
    # Fall back to script location
    if ($ScriptRoot) {
        return Split-Path $ScriptRoot -Parent
    }
    
    throw "Cannot determine project root. Set WORK_RESOURCES_ROOT environment variable or run from scripts directory."
}

function Get-EnvSettings {
    param(
        [string]$ProjectRoot
    )
    
    # Look for .env in config/ subdirectory first, then project root (for backward compatibility)
    $configDir = Join-Path $ProjectRoot "config"
    $envPath = Join-Path $configDir ".env"
    
    if (-not (Test-Path $envPath)) {
        # Fall back to project root for backward compatibility
        $envPath = Join-Path $ProjectRoot ".env"
    }
    
    $templatePath = Join-Path $configDir ".env.template"
    if (-not (Test-Path $templatePath)) {
        $templatePath = Join-Path $ProjectRoot ".env.template"
    }
    
    if (-not (Test-Path $envPath)) {
        if (Test-Path $templatePath) {
            throw "Configuration not found. Please copy .env.template to .env and fill in your values."
        } else {
            throw "Configuration not found. Please create a .env file with VAULT_NAME, RESOURCE_GROUP_NAME, and optionally SUBSCRIPTION_ID."
        }
    }
    
    # Parse .env file
    $settings = @{
        vaultName = ""
        resourceGroupName = ""
        subscriptionId = ""
    }
    
    Get-Content $envPath | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split "=", 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $value = $parts[1].Trim()
                # Remove surrounding quotes if present
                $value = $value -replace '^["'']|["'']$', ''
                
                switch ($key) {
                    "VAULT_NAME" { $settings.vaultName = $value }
                    "RESOURCE_GROUP_NAME" { $settings.resourceGroupName = $value }
                    "SUBSCRIPTION_ID" { $settings.subscriptionId = $value }
                }
            }
        }
    }
    
    # Validate required fields
    if ([string]::IsNullOrWhiteSpace($settings.vaultName)) {
        throw "VAULT_NAME is required in .env file"
    }
    if ([string]::IsNullOrWhiteSpace($settings.resourceGroupName)) {
        throw "RESOURCE_GROUP_NAME is required in .env file"
    }
    
    # Return as PSCustomObject for consistency with previous JSON approach
    return [PSCustomObject]$settings
}

function Get-SetupRole {
    <#
    .SYNOPSIS
        Determines the Azure RBAC role to assign during setup.
    .DESCRIPTION
        Returns a hashtable with AzureRole and Label. New vaults default to Officer,
        existing vaults default to User, unless overridden by -Role.
    #>
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

function Test-SecretsOfficerRole {
    <#
    .SYNOPSIS
        Checks if the current user has Key Vault Secrets Officer role on the vault.
    .DESCRIPTION
        First tries to read role assignments via ARM. If that fails (user may lack
        Microsoft.Authorization/roleAssignments/read permission), falls back to
        probing the Key Vault data-plane by attempting a dummy secret set/delete.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,
        [Parameter(Mandatory)]
        [string]$ResourceGroupName
    )

    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        return $false
    }

    # Strategy 1: Check role assignments (requires ARM read permission).
    # --include-inherited honors Officer/Administrator roles inherited from the
    # resource group or subscription scope, which is the common case.
    $vaultId = az keyvault show --name $VaultName --resource-group $ResourceGroupName --query "id" -o tsv 2>$null
    if (-not [string]::IsNullOrWhiteSpace($vaultId)) {
        $assignee = $account.user.name
        $roles = az role assignment list --assignee $assignee --scope $vaultId --include-inherited --query "[].roleDefinitionName" -o json 2>$null | ConvertFrom-Json

        if ($null -ne $roles -and $roles.Count -gt 0) {
            # Role query succeeded — trust the result
            if ($roles -contains "Key Vault Secrets Officer" -or $roles -contains "Key Vault Administrator") {
                return $true
            }
            return $false
        }
    }

    # Strategy 2: Probe data-plane write access by attempting to set a known test secret.
    # Only reached when Strategy 1 returns no info (e.g., the caller lacks
    # Microsoft.Authorization/roleAssignments/read but still has data-plane perms).
    $probeName = "wr-access-probe"
    $probeOutput = az keyvault secret set --vault-name $VaultName --name $probeName --value "probe" 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Best-effort cleanup: delete + purge so we don't leave a soft-deleted
        # secret cluttering the vault. Purge will silently fail when purge
        # protection is enabled, which is acceptable.
        az keyvault secret delete --vault-name $VaultName --name $probeName 2>$null | Out-Null
        az keyvault secret purge --vault-name $VaultName --name $probeName 2>$null | Out-Null
        return $true
    }

    return $false
}

function Assert-SecretsOfficerRole {
    <#
    .SYNOPSIS
        Asserts that the current user has write access to the vault. Exits with error if not.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,
        [Parameter(Mandatory)]
        [string]$ResourceGroupName
    )

    if (-not (Test-SecretsOfficerRole -VaultName $VaultName -ResourceGroupName $ResourceGroupName)) {
        Write-Host "`n[ERROR] You don't have write access to vault '$VaultName'." -ForegroundColor Red
        Write-Host "   You need the 'Key Vault Secrets Officer' or 'Key Vault Administrator' role." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host "   To get write access, ask a vault admin to run:" -ForegroundColor Yellow
        Write-Host "   wr-add-user -Email your@email.com -Role Admin" -ForegroundColor Cyan
        Write-Host "" -ForegroundColor Yellow
        Write-Host "   Or re-run setup with the Admin role:" -ForegroundColor Yellow
        Write-Host "   wr-setup -Role Admin" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }
}
