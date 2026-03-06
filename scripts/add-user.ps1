#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Grant a user access to the Azure KeyVault.

.DESCRIPTION
    Assigns a KeyVault RBAC role to a user. By default, assigns the 
    "Key Vault Secrets User" role (read-only). Use -Role Admin to grant 
    "Key Vault Secrets Officer" (read + write).

.PARAMETER Email
    The email (UPN) of the user to grant access to.

.PARAMETER Role
    The role to assign. Values: Admin, User.
    - Admin: Assigns 'Key Vault Secrets Officer' (read + write secrets)
    - User: Assigns 'Key Vault Secrets User' (read-only)
    Default: User

.PARAMETER Remove
    Remove the user's role assignment instead of adding it.

.EXAMPLE
    ./add-user.ps1 -Email teammate@company.com
    Grants read-only access to the vault.

.EXAMPLE
    ./add-user.ps1 -Email teammate@company.com -Role Admin
    Grants read + write access to the vault.

.EXAMPLE
    ./add-user.ps1 -Email teammate@company.com -Remove
    Removes the user's access to the vault.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Email,

    [ValidateSet("Admin", "User")]
    [string]$Role = "User",

    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot

# Load shared helpers
. (Join-Path $ScriptRoot "common.ps1")

# Resolve paths (supports WORK_RESOURCES_ROOT env var)
$ProjectRoot = Get-ProjectRoot -ScriptRoot $ScriptRoot

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

function Get-Settings {
    return Get-EnvSettings -ProjectRoot $ProjectRoot
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

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

$action = if ($Remove) { "Remove User Access" } else { "Grant User Access" }
Write-Host "`n[KEY] $action" -ForegroundColor Magenta

# Check Azure login
Write-Step "Verifying Azure authentication..."
$account = Test-AzureLogin
Write-Success "Logged in as: $($account.user.name)"

# Load configuration
Write-Step "Loading configuration..."
$settings = Get-Settings

# Ensure we're using the configured subscription
if (-not [string]::IsNullOrWhiteSpace($settings.subscriptionId)) {
    if ($account.id -ne $settings.subscriptionId) {
        Write-Info "Switching to configured subscription..."
        az account set --subscription $settings.subscriptionId
        $account = az account show | ConvertFrom-Json
    }
}
Write-Success "Subscription: $($account.name)"

# Verify the caller has Officer role (must be admin to manage users)
Write-Step "Verifying your permissions..."
Assert-SecretsOfficerRole -VaultName $settings.vaultName -ResourceGroupName $settings.resourceGroupName
Write-Success "You have admin access"

# Get vault ID
$vaultId = az keyvault show --name $settings.vaultName --resource-group $settings.resourceGroupName --query "id" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($vaultId)) {
    Write-Host "`n[ERROR] Could not find KeyVault '$($settings.vaultName)' in resource group '$($settings.resourceGroupName)'" -ForegroundColor Red
    exit 1
}

# Determine the Azure role
$azureRole = if ($Role -eq "Admin") { "Key Vault Secrets Officer" } else { "Key Vault Secrets User" }
$roleLabel = if ($Role -eq "Admin") { "Admin (read + write)" } else { "User (read-only)" }

if ($Remove) {
    # Remove role assignment
    Write-Step "Removing '$azureRole' role from $Email..."

    $removeOutput = az role assignment delete `
        --role $azureRole `
        --assignee $Email `
        --scope $vaultId 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Success "Removed '$azureRole' role from $Email"
    } else {
        if ($removeOutput -match "AADSTS530084|conditional access|token protection") {
            Write-Warn "Your organization's security policy is blocking role changes via CLI."
            Write-Host ""
            Write-Host "   Please remove the role manually using Azure Portal:" -ForegroundColor Yellow
            Write-Host "   1. Go to: https://portal.azure.com" -ForegroundColor White
            Write-Host "   2. Navigate to: KeyVault '$($settings.vaultName)' > Access control (IAM)" -ForegroundColor White
            Write-Host "   3. Find and remove role assignment for: $Email" -ForegroundColor White
            Write-Host ""
        } else {
            Write-Host "`n[ERROR] Failed to remove role:" -ForegroundColor Red
            Write-Host $removeOutput -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "`n+==============================================================+" -ForegroundColor Green
    Write-Host "|                  Access Removed                              |" -ForegroundColor Green
    Write-Host "+==============================================================+" -ForegroundColor Green
    Write-Host "`n  User:  $Email" -ForegroundColor White
    Write-Host "  Role:  $azureRole (removed)" -ForegroundColor White
    Write-Host "  Vault: $($settings.vaultName)" -ForegroundColor White
    Write-Host ""
} else {
    # Assign role
    Write-Step "Assigning '$azureRole' role to $Email..."

    $assignOutput = az role assignment create `
        --role $azureRole `
        --assignee $Email `
        --scope $vaultId 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Success "Assigned '$azureRole' role to $Email"
        Write-Info "Note: Role assignment may take 1-2 minutes to propagate"
    } else {
        if ($assignOutput -match "AADSTS530084|conditional access|token protection") {
            Write-Warn "Your organization's security policy is blocking role assignment via CLI."
            Write-Host ""
            Write-Host "   Please assign the role manually using Azure Portal:" -ForegroundColor Yellow
            Write-Host "   1. Go to: https://portal.azure.com" -ForegroundColor White
            Write-Host "   2. Navigate to: KeyVault '$($settings.vaultName)' > Access control (IAM)" -ForegroundColor White
            Write-Host "   3. Click 'Add role assignment'" -ForegroundColor White
            Write-Host "   4. Select role: '$azureRole'" -ForegroundColor White
            Write-Host "   5. Assign to: $Email" -ForegroundColor White
            Write-Host ""
            Write-Host "   Or ask your Azure admin to run:" -ForegroundColor Yellow
            Write-Host "   az role assignment create --role '$azureRole' --assignee $Email --scope $vaultId" -ForegroundColor Cyan
        } else {
            Write-Host "`n[ERROR] Failed to assign role:" -ForegroundColor Red
            Write-Host $assignOutput -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "`n+==============================================================+" -ForegroundColor Green
    Write-Host "|                  Access Granted                              |" -ForegroundColor Green
    Write-Host "+==============================================================+" -ForegroundColor Green
    Write-Host "`n  User:  $Email" -ForegroundColor White
    Write-Host "  Role:  $roleLabel" -ForegroundColor White
    Write-Host "  Vault: $($settings.vaultName)" -ForegroundColor White

    Write-Host "`nTell them to run:" -ForegroundColor Yellow
    Write-Host "  1. Clone the repo and run: ./install.ps1" -ForegroundColor White
    Write-Host "  2. Set their .env with:" -ForegroundColor White
    Write-Host "       VAULT_NAME=$($settings.vaultName)" -ForegroundColor White
    Write-Host "       RESOURCE_GROUP_NAME=$($settings.resourceGroupName)" -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($settings.subscriptionId)) {
        Write-Host "       SUBSCRIPTION_ID=$($settings.subscriptionId)" -ForegroundColor White
    }
    Write-Host "  3. Run: wr-setup" -ForegroundColor White
    Write-Host ""
}
