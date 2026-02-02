#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Delete a secret from Azure KeyVault.

.DESCRIPTION
    Removes a secret from KeyVault. Can delete individual secrets or all 
    secrets for a resource prefix.

.PARAMETER Resource
    The resource prefix (e.g., "myapp", "database", "shared").
    Must start with a letter and contain only letters, numbers, and hyphens.

.PARAMETER Name
    The secret name within the resource (e.g., "api-key", "connection-string").
    Required unless -All is specified.

.PARAMETER All
    Delete all secrets with names starting with the specified resource prefix.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -Name api-key
    Deletes a single secret after confirmation.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -All
    Deletes all secrets with names starting with 'myapp-' after confirmation.

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

function Get-SecretEnvVarName {
    param([string]$VaultName, [string]$SecretName)
    $secretData = az keyvault secret show --vault-name $VaultName --name $SecretName --query "tags.\"env-var-name\"" -o tsv 2>$null
    return $secretData
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

# Build list of secrets to delete
$secretsToDelete = @()

if ($All) {
    # List all secrets from vault and filter by resource tag
    Write-Step "Finding secrets with resource tag '$Resource'..."
    
    $allSecrets = az keyvault secret list --vault-name $settings.vaultName --query "[].{name:name, tags:tags}" -o json 2>$null | ConvertFrom-Json
    
    foreach ($secret in $allSecrets) {
        if ($secret.tags -and $secret.tags.resource -eq $Resource) {
            $envVarName = if ($secret.tags."env-var-name") { $secret.tags."env-var-name" } else { $null }
            $secretsToDelete += @{
                SecretName = $secret.name
                EnvVarName = $envVarName
            }
        }
    }
    
    if ($secretsToDelete.Count -eq 0) {
        Write-Err "No secrets found with resource tag '$Resource' in vault."
        Write-Host "  Run wr-list to see available secrets.`n" -ForegroundColor DarkGray
        exit 1
    }
} else {
    $secretName = "$Resource-$Name"
    
    # Check if secret exists in KeyVault
    Write-Step "Checking if secret exists..."
    $secretExistsInVault = Test-SecretExistsInVault -VaultName $settings.vaultName -SecretName $secretName
    
    if (-not $secretExistsInVault) {
        Write-Err "Secret '$secretName' not found in KeyVault '$($settings.vaultName)'."
        Write-Host "`n  The secret may have already been deleted or never existed.`n" -ForegroundColor DarkGray
        exit 1
    }
    
    $envVarName = Get-SecretEnvVarName -VaultName $settings.vaultName -SecretName $secretName
    
    $secretsToDelete += @{
        SecretName = $secretName
        EnvVarName = $envVarName
    }
}

# Display what will be deleted
Write-Step "Secrets to delete from '$($settings.vaultName)':"
foreach ($secret in $secretsToDelete) {
    $envInfo = if ($secret.EnvVarName) { " -> `$env:$($secret.EnvVarName)" } else { " (no env-var-name tag)" }
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
    $deleted = Remove-SecretFromVault -VaultName $settings.vaultName -SecretName $secret.SecretName
    if ($deleted) {
        Write-Success "Deleted: $($secret.SecretName)"
        $deletedCount++
    } else {
        Write-Err "Failed to delete: $($secret.SecretName)"
        $failedCount++
    }
}

# Summary
Write-Host "`n+==============================================================+" -ForegroundColor Green
Write-Host "|                    Deletion Complete                         |" -ForegroundColor Green
Write-Host "+==============================================================+`n" -ForegroundColor Green

Write-Host "Deleted $deletedCount secret(s)" -ForegroundColor White
if ($failedCount -gt 0) {
    Write-Host "Failed to delete $failedCount secret(s)" -ForegroundColor Red
}
Write-Host ""
