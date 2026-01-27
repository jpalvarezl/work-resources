#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Setup Azure KeyVault for secrets management. Creates vault if it doesn't exist.

.DESCRIPTION
    This script:
    1. Verifies Azure CLI is installed
    2. Logs you into Azure (interactive)
    3. Creates the resource group if missing
    4. Creates the KeyVault if missing (auto-detects location)
    5. Assigns "Key Vault Secrets Officer" role to your user

.EXAMPLE
    ./setup.ps1
    
.EXAMPLE
    ./setup.ps1 -Force
    Re-runs setup even if vault already exists (useful to fix permissions)
#>

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$ConfigRoot = Join-Path (Split-Path $ScriptRoot -Parent) "config"

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

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-Settings {
    $settingsPath = Join-Path $ConfigRoot "settings.json"
    if (-not (Test-Path $settingsPath)) {
        throw "Settings file not found: $settingsPath`nPlease create it from the template."
    }
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    
    # Validate required fields
    if ([string]::IsNullOrWhiteSpace($settings.vaultName)) {
        throw "vaultName is required in settings.json"
    }
    if ([string]::IsNullOrWhiteSpace($settings.resourceGroupName)) {
        throw "resourceGroupName is required in settings.json"
    }
    
    return $settings
}

# -----------------------------------------------------------------------------
# Main Setup Logic
# -----------------------------------------------------------------------------

Write-Host "`n+==============================================================+" -ForegroundColor Magenta
Write-Host "|       Azure KeyVault Secrets Manager - Setup                 |" -ForegroundColor Magenta
Write-Host "+==============================================================+" -ForegroundColor Magenta

# Step 1: Check Azure CLI
Write-Step "Checking prerequisites..."

if (-not (Test-CommandExists "az")) {
    Write-Host "`n[ERROR] Azure CLI is not installed." -ForegroundColor Red
    Write-Host "`nInstall it using:" -ForegroundColor Yellow
    Write-Host "  Windows:  winget install Microsoft.AzureCLI" -ForegroundColor White
    Write-Host "  macOS:    brew install azure-cli" -ForegroundColor White
    Write-Host "  Linux:    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash" -ForegroundColor White
    exit 1
}
Write-Success "Azure CLI is installed"

$azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
Write-Info "Version: $azVersion"

# Step 2: Login to Azure
Write-Step "Checking Azure authentication..."

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Info "Not logged in. Opening browser for authentication..."
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Success "Logged in as: $($account.user.name)"
Write-Info "Subscription: $($account.name) ($($account.id))"

# Step 3: Load settings
Write-Step "Loading configuration..."
$settings = Get-Settings
Write-Success "Vault name: $($settings.vaultName)"
Write-Success "Resource group: $($settings.resourceGroupName)"

# Use specified subscription or default
if (-not [string]::IsNullOrWhiteSpace($settings.subscriptionId)) {
    Write-Info "Switching to subscription: $($settings.subscriptionId)"
    az account set --subscription $settings.subscriptionId
    $account = az account show | ConvertFrom-Json
    Write-Success "Using subscription: $($account.name)"
}

# Step 4: Check if vault exists
Write-Step "Checking KeyVault status..."

$vaultExists = $false
$vaultJson = $null
try {
    $vaultJson = az keyvault show --name $settings.vaultName 2>&1
    if ($LASTEXITCODE -eq 0) {
        $vault = $vaultJson | ConvertFrom-Json
        $vaultExists = $true
        Write-Success "KeyVault '$($settings.vaultName)' already exists"
        Write-Info "Location: $($vault.location)"
        
        if (-not $Force) {
            Write-Host "`n[SUCCESS] Setup complete! Vault is ready to use." -ForegroundColor Green
            Write-Host "   Run with -Force to re-apply permissions if needed.`n" -ForegroundColor DarkGray
        }
    }
} catch {
    # Vault doesn't exist, will create it
}

# Step 5: Create resource group and vault if needed
if (-not $vaultExists -or $Force) {
    
    if (-not $vaultExists) {
        # Auto-detect location from subscription
        Write-Step "Detecting optimal Azure region..."
        
        # Use single quotes and escape brackets to avoid PowerShell parsing issues
        $jmesQuery = '[?metadata.regionCategory==`Recommended`] | [0].name'
        $location = az account list-locations --query $jmesQuery -o tsv 2>$null
        if ([string]::IsNullOrWhiteSpace($location)) {
            $location = "eastus"  # Fallback
        }
        Write-Success "Using region: $location"
        
        # Create resource group
        Write-Step "Creating resource group '$($settings.resourceGroupName)'..."
        
        $rgExists = az group show --name $settings.resourceGroupName 2>$null
        if ($rgExists) {
            Write-Info "Resource group already exists"
        } else {
            az group create --name $settings.resourceGroupName --location $location | Out-Null
            Write-Success "Resource group created"
        }
        
        # Create KeyVault
        Write-Step "Creating KeyVault '$($settings.vaultName)'..."
        Write-Info "This may take a minute..."
        
        az keyvault create `
            --name $settings.vaultName `
            --resource-group $settings.resourceGroupName `
            --location $location `
            --enable-rbac-authorization true | Out-Null
        
        Write-Success "KeyVault created successfully"
    }
    
    # Assign permissions
    Write-Step "Configuring access permissions..."
    
    $userObjectId = az ad signed-in-user show --query "id" -o tsv 2>$null
    if ($userObjectId) {
        $vaultId = az keyvault show --name $settings.vaultName --query "id" -o tsv
        
        # Check if role already assigned
        $existingRole = az role assignment list `
            --assignee $userObjectId `
            --scope $vaultId `
            --role "Key Vault Secrets Officer" 2>$null | ConvertFrom-Json
        
        if ($existingRole -and $existingRole.Count -gt 0) {
            Write-Info "Secrets Officer role already assigned"
        } else {
            az role assignment create `
                --role "Key Vault Secrets Officer" `
                --assignee $userObjectId `
                --scope $vaultId | Out-Null
            Write-Success "Assigned 'Key Vault Secrets Officer' role to your user"
        }
    } else {
        Write-Warn "Could not determine user ID for role assignment"
        Write-Warn "You may need to manually assign 'Key Vault Secrets Officer' role"
    }
}

# Final summary
Write-Host "`n+==============================================================+" -ForegroundColor Green
Write-Host "|                    Setup Complete!                           |" -ForegroundColor Green
Write-Host "+==============================================================+" -ForegroundColor Green

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Add a secret:     ./scripts/save-secret.ps1 -Resource myapp -Name api-key" -ForegroundColor White
Write-Host "  2. Load secrets:     ./scripts/load-env.ps1 -Resource myapp" -ForegroundColor White
Write-Host "  3. List secrets:     ./scripts/list-secrets.ps1" -ForegroundColor White
Write-Host ""
