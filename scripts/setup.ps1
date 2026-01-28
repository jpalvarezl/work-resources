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
$ProjectRoot = Split-Path $ScriptRoot -Parent
$ConfigRoot = Join-Path $ProjectRoot "config"

# Load shared helpers
. (Join-Path $ScriptRoot "common.ps1")

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
    return Get-EnvSettings -ProjectRoot $ProjectRoot
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

# Step 2: Load settings first (needed for subscription ID)
Write-Step "Loading configuration..."
$settings = Get-Settings
Write-Success "Vault name: $($settings.vaultName)"
Write-Success "Resource group: $($settings.resourceGroupName)"

# Step 3: Login to Azure
Write-Step "Checking Azure authentication..."

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Info "Not logged in. Opening browser for authentication..."
    # If subscription ID is configured, use it during login to skip interactive picker
    if (-not [string]::IsNullOrWhiteSpace($settings.subscriptionId)) {
        az login --output none
        az account set --subscription $settings.subscriptionId
    } else {
        az login
    }
    $account = az account show | ConvertFrom-Json
}
Write-Success "Logged in as: $($account.user.name)"

# Ensure we're using the configured subscription
if (-not [string]::IsNullOrWhiteSpace($settings.subscriptionId)) {
    if ($account.id -ne $settings.subscriptionId) {
        Write-Info "Switching to configured subscription..."
        az account set --subscription $settings.subscriptionId
        $account = az account show | ConvertFrom-Json
    }
}
Write-Success "Subscription: $($account.name)"

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
        
        $createOutput = az keyvault create `
            --name $settings.vaultName `
            --resource-group $settings.resourceGroupName `
            --location $location `
            --enable-rbac-authorization true 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            # Check if it's just "already exists" error
            if ($createOutput -match "already exists") {
                Write-Info "KeyVault already exists"
            } else {
                Write-Host "`n[ERROR] Failed to create KeyVault:" -ForegroundColor Red
                Write-Host $createOutput -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Success "KeyVault created successfully"
        }
    }
    
    # Assign permissions
    Write-Step "Configuring access permissions..."
    
    $roleAssigned = $false
    $vaultId = az keyvault show --name $settings.vaultName --resource-group $settings.resourceGroupName --query "id" -o tsv 2>$null
    
    if ([string]::IsNullOrWhiteSpace($vaultId)) {
        Write-Host "`n[ERROR] Could not find KeyVault '$($settings.vaultName)' in resource group '$($settings.resourceGroupName)'" -ForegroundColor Red
        exit 1
    }
    
    # First, test if we already have access by trying to list secrets
    Write-Info "Testing vault access..."
    $testAccess = az keyvault secret list --vault-name $settings.vaultName --query "[].name" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "You already have access to the vault"
        $roleAssigned = $true
    } else {
        # Don't have access, try to assign role
        $assignee = $account.user.name
        Write-Info "Assignee: $assignee"
        Write-Info "Vault ID: $vaultId"
        
        # Try to assign role
        Write-Info "Attempting to assign 'Key Vault Secrets Officer' role..."
        $roleOutput = az role assignment create `
            --role "Key Vault Secrets Officer" `
            --assignee $assignee `
            --scope $vaultId 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Assigned 'Key Vault Secrets Officer' role to your user"
            Write-Info "Note: Role assignment may take 1-2 minutes to propagate"
            $roleAssigned = $true
        } else {
            # Check if it's a conditional access policy issue
            if ($roleOutput -match "AADSTS530084|conditional access|token protection") {
                Write-Warn "Your organization's security policy is blocking role assignment via CLI."
                Write-Host ""
                Write-Host "   Please assign the role manually using Azure Portal:" -ForegroundColor Yellow
                Write-Host "   1. Go to: https://portal.azure.com" -ForegroundColor White
                Write-Host "   2. Navigate to: KeyVault '$($settings.vaultName)' > Access control (IAM)" -ForegroundColor White
                Write-Host "   3. Click 'Add role assignment'" -ForegroundColor White
                Write-Host "   4. Select role: 'Key Vault Secrets Officer'" -ForegroundColor White
                Write-Host "   5. Assign to: $assignee" -ForegroundColor White
                Write-Host ""
                Write-Host "   Or ask your Azure admin to run:" -ForegroundColor Yellow
                Write-Host "   az role assignment create --role 'Key Vault Secrets Officer' --assignee $assignee --scope $vaultId" -ForegroundColor Cyan
            } else {
                Write-Host "`n[ERROR] Failed to assign role:" -ForegroundColor Red
                Write-Host $roleOutput -ForegroundColor Red
            }
        }
    }
    
    if (-not $roleAssigned) {
        Write-Host "`n[!] Setup partially complete - role assignment pending." -ForegroundColor Yellow
        Write-Host "   Complete the manual role assignment above, then re-run this script to verify." -ForegroundColor Yellow
        exit 1
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
