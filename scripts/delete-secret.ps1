#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Delete a secret from Azure KeyVault.

.DESCRIPTION
    Removes a secret from KeyVault and updates the local resources.json config.
    Can delete individual secrets or all secrets for a resource.

.PARAMETER Resource
    The resource group name (e.g., "myapp", "database", "shared").
    Must start with a letter and contain only letters, numbers, and hyphens.

.PARAMETER Name
    The secret name within the resource (e.g., "api-key", "connection-string").
    Required unless -All is specified.

.PARAMETER All
    Delete all secrets for the specified resource.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -Name api-key
    Deletes a single secret after confirmation.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -All
    Deletes all secrets for the 'myapp' resource after confirmation.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -Name api-key -Force
    Deletes without confirmation prompt.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Resource,
    
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Name,
    
    [switch]$All,
    
    [switch]$Force
)

# Validate parameters
if (-not $All -and -not $Name) {
    throw "You must specify either -Name or -All"
}

if ($All -and $Name) {
    throw "Cannot use both -Name and -All together"
}

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot

# Load shared helpers
. (Join-Path $ScriptRoot "common.ps1")

# Resolve paths (supports WORK_RESOURCES_ROOT env var)
$ProjectRoot = Get-ProjectRoot -ScriptRoot $ScriptRoot
$ConfigRoot = Join-Path $ProjectRoot "config"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [i] $Message" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "  [X] $Message" -ForegroundColor Red
}

function Get-Settings {
    return Get-EnvSettings -ProjectRoot $ProjectRoot
}

function Get-ResourcesConfig {
    $resourcesPath = Join-Path $ConfigRoot "resources.json"
    if (-not (Test-Path $resourcesPath)) {
        throw "Resources file not found. Run setup.ps1 first."
    }
    return Get-Content $resourcesPath -Raw | ConvertFrom-Json
}

function Save-ResourcesConfig {
    param($Config)
    $resourcesPath = Join-Path $ConfigRoot "resources.json"
    $Config | ConvertTo-Json -Depth 10 | Set-Content $resourcesPath -Encoding UTF8
}

function Test-AzureLogin {
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Info "Not logged in. Running 'az login'..."
        az login | Out-Null
        $account = az account show | ConvertFrom-Json
    }
    return $account
}

function Test-SecretExistsInVault {
    param([string]$VaultName, [string]$SecretName)
    $secret = az keyvault secret show --vault-name $VaultName --name $SecretName 2>$null
    return $null -ne $secret
}

function Remove-SecretFromVault {
    param([string]$VaultName, [string]$SecretName)
    az keyvault secret delete --vault-name $VaultName --name $SecretName 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

Write-Host "`n[KEY] Delete Secret from KeyVault" -ForegroundColor Magenta

# Check Azure login
Write-Step "Verifying Azure authentication..."
$account = Test-AzureLogin
Write-Success "Logged in as: $($account.user.name)"

# Load configuration
$settings = Get-Settings
$resourcesConfig = Get-ResourcesConfig

# Check if resource exists in config
$resourceData = $resourcesConfig.resources.$Resource
$resourceExistsInConfig = $null -ne $resourceData

# Build list of secrets to delete
$secretsToDelete = @()

if ($All) {
    if ($resourceExistsInConfig -and $resourceData.secrets) {
        foreach ($prop in $resourceData.secrets.PSObject.Properties) {
            $secretsToDelete += @{
                SecretName = $prop.Name
                EnvVarName = $prop.Value
            }
        }
    }
    
    if ($secretsToDelete.Count -eq 0) {
        Write-Err "Resource '$Resource' not found in configuration or has no secrets."
        Write-Host "  Run ./list-secrets.ps1 to see available resources.`n" -ForegroundColor DarkGray
        exit 1
    }
} else {
    $secretName = "$Resource-$Name"
    $envVarName = $null
    
    # Check if secret exists in config
    $secretExistsInConfig = $false
    if ($resourceExistsInConfig -and $resourceData.secrets.PSObject.Properties[$secretName]) {
        $secretExistsInConfig = $true
        $envVarName = $resourceData.secrets.$secretName
    }
    
    # Check if secret exists in KeyVault
    Write-Step "Checking if secret exists..."
    $secretExistsInVault = Test-SecretExistsInVault -VaultName $settings.vaultName -SecretName $secretName
    
    if (-not $secretExistsInConfig -and -not $secretExistsInVault) {
        Write-Err "Secret '$secretName' not found."
        Write-Host "  - Not in local configuration (resources.json)" -ForegroundColor DarkGray
        Write-Host "  - Not in KeyVault '$($settings.vaultName)'" -ForegroundColor DarkGray
        Write-Host "`n  The secret may have already been deleted or never existed.`n" -ForegroundColor DarkGray
        exit 1
    }
    
    $secretsToDelete += @{
        SecretName = $secretName
        EnvVarName = $envVarName
        ExistsInConfig = $secretExistsInConfig
        ExistsInVault = $secretExistsInVault
    }
}

# Display what will be deleted
Write-Step "Secrets to delete from '$($settings.vaultName)':"
foreach ($secret in $secretsToDelete) {
    $envInfo = if ($secret.EnvVarName) { " -> `$env:$($secret.EnvVarName)" } else { "" }
    Write-Host "  - $($secret.SecretName)$envInfo" -ForegroundColor Yellow
}

# Confirmation prompt
if (-not $Force) {
    Write-Host ""
    $confirm = Read-Host "Are you sure you want to delete these secret(s)? (y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Warn "Cancelled."
        exit 0
    }
}

# Delete from KeyVault
Write-Step "Deleting from KeyVault..."
$deletedCount = 0
$failedCount = 0

foreach ($secret in $secretsToDelete) {
    $existsInVault = if ($null -ne $secret.ExistsInVault) { 
        $secret.ExistsInVault 
    } else { 
        Test-SecretExistsInVault -VaultName $settings.vaultName -SecretName $secret.SecretName 
    }
    
    if ($existsInVault) {
        $deleted = Remove-SecretFromVault -VaultName $settings.vaultName -SecretName $secret.SecretName
        if ($deleted) {
            Write-Success "Deleted: $($secret.SecretName)"
            $deletedCount++
        } else {
            Write-Err "Failed to delete: $($secret.SecretName)"
            $failedCount++
        }
    } else {
        Write-Warn "Not in KeyVault (skipped): $($secret.SecretName)"
    }
}

# Update local configuration
Write-Step "Updating local configuration..."

if ($All) {
    # Remove entire resource
    $resourcesConfig.resources.PSObject.Properties.Remove($Resource)
    Write-Success "Removed resource '$Resource' from resources.json"
} else {
    # Remove single secret
    if ($resourceExistsInConfig -and $resourceData.secrets.PSObject.Properties[$secretsToDelete[0].SecretName]) {
        $resourceData.secrets.PSObject.Properties.Remove($secretsToDelete[0].SecretName)
        
        # If no more secrets in resource, remove the resource too
        $remainingSecrets = @($resourceData.secrets.PSObject.Properties).Count
        if ($remainingSecrets -eq 0) {
            $resourcesConfig.resources.PSObject.Properties.Remove($Resource)
            Write-Success "Removed secret and empty resource '$Resource' from resources.json"
        } else {
            Write-Success "Removed secret from resources.json ($remainingSecrets secret(s) remaining in resource)"
        }
    } else {
        Write-Info "Secret was not in resources.json (already clean)"
    }
}

Save-ResourcesConfig -Config $resourcesConfig

# Summary
Write-Host "`n+==============================================================+" -ForegroundColor Green
Write-Host "|                    Deletion Complete                         |" -ForegroundColor Green
Write-Host "+==============================================================+`n" -ForegroundColor Green

Write-Host "Summary:"
Write-Host "  Deleted from KeyVault: $deletedCount"
if ($failedCount -gt 0) {
    Write-Host "  Failed: $failedCount" -ForegroundColor Red
}
Write-Host ""
