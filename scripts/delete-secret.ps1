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

.PARAMETER Flavor
    Optional: Restrict the operation to secrets tagged with the given flavor.
    For single delete (-Name), the secret name becomes "{Resource}-{Flavor}-{Name}"
    and the secret's 'flavor' tag must match before deletion proceeds.
    For -All, this is an additional filter (comma-separated list allowed).

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -Name api-key
    Deletes a single secret after confirmation.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -All
    Deletes all secrets with resource tag 'myapp' after confirmation.

.EXAMPLE
    ./delete-secret.ps1 -Resource myapp -Name api-key -Force
    Deletes without confirmation prompt.

.EXAMPLE
    ./delete-secret.ps1 -Resource foundry-sdk-deployment -Flavor py -Name foundry-project-endpoint
    Deletes 'foundry-sdk-deployment-py-foundry-project-endpoint', verifying flavor=py tag first.

.EXAMPLE
    ./delete-secret.ps1 -Resource foundry-sdk-deployment -All -Flavor py -Force
    Deletes every secret tagged resource='foundry-sdk-deployment' AND flavor='py'.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Resource,
    
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Name,
    
    [switch]$All,
    
    [switch]$Force,

    [string]$Flavor
)

# Validate Flavor format if provided (comma-list pattern for -All, single value for -Name).
if (-not [string]::IsNullOrWhiteSpace($Flavor)) {
    foreach ($f in ($Flavor -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($f -notmatch '^[a-z]([a-z0-9-]*[a-z0-9])?$') {
            throw "Invalid flavor '$f'. Must be lowercase, start with a letter, and contain only letters, digits, and internal hyphens."
        }
    }
}

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

# Verify write access
Assert-SecretsOfficerRole -VaultName $settings.vaultName -ResourceGroupName $settings.resourceGroupName

# Build list of secrets to delete
$secretsToDelete = @()

if ($All) {
    # List all secrets from vault and filter by resource tag (and optional flavor)
    $flavorFilters = @()
    if (-not [string]::IsNullOrWhiteSpace($Flavor)) {
        $flavorFilters = @($Flavor -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Write-Step "Finding secrets with resource tag '$Resource' AND flavor in ($($flavorFilters -join ', '))..."
    } else {
        Write-Step "Finding secrets with resource tag '$Resource'..."
    }
    
    $allSecrets = az keyvault secret list --vault-name $settings.vaultName --query "[].{name:name, tags:tags}" -o json 2>$null | ConvertFrom-Json
    
    foreach ($secret in $allSecrets) {
        if (-not (Test-SecretTagsMatchFilter -Tags $secret.tags -ResourceFilters @($Resource) -FlavorFilters $flavorFilters)) {
            continue
        }
        $envVarName = if ($secret.tags."env-var-name") { $secret.tags."env-var-name" } else { $null }
        $secretsToDelete += @{
            SecretName = $secret.name
            EnvVarName = $envVarName
        }
    }
    
    if ($secretsToDelete.Count -eq 0) {
        $filterDesc = "resource tag '$Resource'"
        if ($flavorFilters.Count -gt 0) { $filterDesc += " AND flavor in ($($flavorFilters -join ', '))" }
        Write-Err "No secrets found with $filterDesc in vault."
        Write-Host "  Run wr-list to see available secrets.`n" -ForegroundColor DarkGray
        exit 1
    }
} else {
    # Single delete. When -Flavor is supplied, embed it in the composed name AND
    # verify the secret's tags before removing it, so we never silently nuke a
    # legacy secret that happens to share the composed name.
    if ([string]::IsNullOrWhiteSpace($Flavor)) {
        $secretName = "$Resource-$Name"
    } else {
        $secretName = "$Resource-$Flavor-$Name"
    }

    Write-Step "Checking if secret exists..."
    $secretFull = az keyvault secret show --vault-name $settings.vaultName --name $secretName 2>$null | ConvertFrom-Json

    if (-not $secretFull) {
        Write-Err "Secret '$secretName' not found in KeyVault '$($settings.vaultName)'."
        Write-Host "`n  The secret may have already been deleted or never existed.`n" -ForegroundColor DarkGray
        exit 1
    }

    # Safety check: when -Flavor is supplied, refuse to delete a secret whose
    # tags don't actually carry that flavor (or whose resource tag mismatches).
    if (-not [string]::IsNullOrWhiteSpace($Flavor)) {
        $actualResource = if ($secretFull.tags) { $secretFull.tags.resource } else { $null }
        $actualFlavor = if ($secretFull.tags) { $secretFull.tags.flavor } else { $null }
        if ($actualResource -ne $Resource -or $actualFlavor -ne $Flavor) {
            Write-Err "Tag verification failed for '$secretName':"
            Write-Host "  expected resource='$Resource', flavor='$Flavor'" -ForegroundColor DarkGray
            Write-Host "  actual   resource='$actualResource', flavor='$actualFlavor'" -ForegroundColor DarkGray
            Write-Host "`n  Refusing to delete. Use the unflavored form or correct -Flavor.`n" -ForegroundColor DarkGray
            exit 1
        }
    }

    $envVarName = if ($secretFull.tags -and $secretFull.tags.'env-var-name') { $secretFull.tags.'env-var-name' } else { $null }
    
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
