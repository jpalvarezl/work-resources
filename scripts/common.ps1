# Shared helper functions for KeyVault scripts
# This file is dot-sourced by other scripts

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
