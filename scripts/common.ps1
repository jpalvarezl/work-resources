# Shared helper functions for KeyVault scripts
# This file is dot-sourced by other scripts

# Validation patterns - used across multiple scripts
$script:ResourceNamePattern = '^[a-zA-Z][a-zA-Z0-9-]*$'
$script:EnvVarNamePattern = '^[A-Za-z_][A-Za-z0-9_]*$'

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

    # Strategy 1: Check role assignments (requires ARM read permission)
    $vaultId = az keyvault show --name $VaultName --resource-group $ResourceGroupName --query "id" -o tsv 2>$null
    if (-not [string]::IsNullOrWhiteSpace($vaultId)) {
        $assignee = $account.user.name
        $roles = az role assignment list --assignee $assignee --scope $vaultId --query "[].roleDefinitionName" -o json 2>$null | ConvertFrom-Json

        if ($null -ne $roles -and $roles.Count -gt 0) {
            # Role query succeeded — trust the result
            if ($roles -contains "Key Vault Secrets Officer" -or $roles -contains "Key Vault Administrator") {
                return $true
            }
            return $false
        }
    }

    # Strategy 2: Probe data-plane write access by attempting to set a known test secret
    $probeName = "wr-access-probe"
    $probeOutput = az keyvault secret set --vault-name $VaultName --name $probeName --value "probe" 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Clean up the probe secret
        az keyvault secret delete --vault-name $VaultName --name $probeName 2>$null | Out-Null
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
