# Shared helper functions for KeyVault scripts
# This file is dot-sourced by other scripts

function Get-EnvSettings {
    param(
        [string]$ProjectRoot
    )
    
    $envPath = Join-Path $ProjectRoot ".env"
    $templatePath = Join-Path $ProjectRoot ".env.template"
    
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
