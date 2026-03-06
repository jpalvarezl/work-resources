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

function Test-SecretsOfficerRole {
    <#
    .SYNOPSIS
        Checks if the current user has Key Vault Secrets Officer role on the vault.
    .DESCRIPTION
        Returns $true if the user has write access (Officer/Administrator), $false otherwise.
        Used by write commands to provide clear errors for read-only users.
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

    $vaultId = az keyvault show --name $VaultName --resource-group $ResourceGroupName --query "id" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($vaultId)) {
        return $false
    }

    $assignee = $account.user.name
    $roles = az role assignment list --assignee $assignee --scope $vaultId --query "[].roleDefinitionName" -o json 2>$null | ConvertFrom-Json

    if ($roles -contains "Key Vault Secrets Officer" -or $roles -contains "Key Vault Administrator") {
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
        Write-Host "   Your role is 'Key Vault Secrets User' (read-only)." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host "   To modify secrets, ask a vault admin to grant you the Officer role:" -ForegroundColor Yellow
        Write-Host "   wr-add-user -Email your@email.com -Role Admin" -ForegroundColor Cyan
        Write-Host "" -ForegroundColor Yellow
        Write-Host "   Or re-run setup with the Admin role:" -ForegroundColor Yellow
        Write-Host "   wr-setup -Role Admin" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }
}
