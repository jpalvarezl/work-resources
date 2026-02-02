#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrate existing secrets to use the 'env-var-name' and 'resource' tags.

.DESCRIPTION
    This script helps migrate secrets that were created before the tag-based
    approach was implemented. It lists all secrets missing the required tags
    and prompts you to provide the environment variable name and resource for each.

.PARAMETER Force
    Skip confirmation prompts (still prompts for tag values).

.PARAMETER DryRun
    Show what would be done without making any changes.

.EXAMPLE
    ./migrate-secrets.ps1
    Interactively migrate all secrets missing required tags.

.EXAMPLE
    ./migrate-secrets.ps1 -DryRun
    Show which secrets need migration without making changes.
#>

param(
    [switch]$Force,
    [switch]$DryRun
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

function Get-SuggestedEnvVarName {
    param([string]$SecretName)
    # Convert "myapp-api-key" -> "MYAPP_API_KEY"
    return $SecretName.ToUpper() -replace '-', '_'
}

function Get-SuggestedResource {
    param([string]$SecretName)
    # Use first segment before hyphen as default resource
    $parts = $SecretName -split '-'
    return $parts[0]
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

Write-Host "`n[MIGRATE] Migrate Secrets to Tag-Based System" -ForegroundColor Magenta

if ($DryRun) {
    Write-Warn "DRY RUN MODE - No changes will be made"
}

# Check Azure login
Write-Step "Verifying Azure authentication..."
$account = Test-AzureLogin
Write-Success "Logged in as: $($account.user.name)"

# Load configuration
$settings = Get-Settings

Write-Step "Scanning secrets in vault: $($settings.vaultName)"

# List all secrets from KeyVault with their tags
$secretsList = az keyvault secret list --vault-name $settings.vaultName --query "[].{name:name, tags:tags}" -o json 2>$null | ConvertFrom-Json

if ($null -eq $secretsList -or $secretsList.Count -eq 0) {
    Write-Info "No secrets found in vault."
    exit 0
}

# Find secrets missing required tags
$secretsToMigrate = @()
$secretsAlreadyTagged = @()

foreach ($secret in $secretsList) {
    $hasEnvVarName = $secret.tags -and $secret.tags."env-var-name"
    $hasResource = $secret.tags -and $secret.tags.resource
    
    if ($hasEnvVarName -and $hasResource) {
        $secretsAlreadyTagged += @{
            Name = $secret.name
            EnvVarName = $secret.tags."env-var-name"
            Resource = $secret.tags.resource
        }
    } else {
        $secretsToMigrate += @{
            Name = $secret.name
            HasEnvVarName = $hasEnvVarName
            HasResource = $hasResource
            ExistingEnvVarName = if ($hasEnvVarName) { $secret.tags."env-var-name" } else { $null }
            ExistingResource = if ($hasResource) { $secret.tags.resource } else { $null }
        }
    }
}

Write-Info "Total secrets: $($secretsList.Count)"
Write-Info "Fully tagged: $($secretsAlreadyTagged.Count)"
Write-Info "Need migration: $($secretsToMigrate.Count)"

if ($secretsToMigrate.Count -eq 0) {
    Write-Host "`n[SUCCESS] All secrets already have required tags!" -ForegroundColor Green
    exit 0
}

# Show secrets that need migration
Write-Step "Secrets requiring migration:"
foreach ($secret in $secretsToMigrate) {
    $suggestedEnv = Get-SuggestedEnvVarName -SecretName $secret.Name
    $suggestedRes = Get-SuggestedResource -SecretName $secret.Name
    $missing = @()
    if (-not $secret.HasEnvVarName) { $missing += "env-var-name" }
    if (-not $secret.HasResource) { $missing += "resource" }
    Write-Host "  - $($secret.Name)" -ForegroundColor Yellow -NoNewline
    Write-Host " (missing: $($missing -join ', '))" -ForegroundColor DarkGray
}

if ($DryRun) {
    Write-Host "`n[DRY RUN] Would prompt for env var names for $($secretsToMigrate.Count) secret(s)" -ForegroundColor Cyan
    exit 0
}

# Confirm before proceeding
if (-not $Force) {
    Write-Host ""
    $confirm = Read-Host "Proceed with migration? (y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Warn "Cancelled."
        exit 0
    }
}

# Migrate each secret
Write-Step "Migrating secrets..."

$migratedCount = 0
$skippedCount = 0
$failedCount = 0

foreach ($secret in $secretsToMigrate) {
    $secretName = $secret.Name
    $suggestedEnv = Get-SuggestedEnvVarName -SecretName $secretName
    $suggestedRes = Get-SuggestedResource -SecretName $secretName
    
    Write-Host "`n  Secret: " -NoNewline
    Write-Host $secretName -ForegroundColor White
    
    # Get env-var-name (use existing if present)
    $envVarName = $null
    if ($secret.HasEnvVarName) {
        $envVarName = $secret.ExistingEnvVarName
        Write-Host "  env-var-name: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$envVarName (existing)" -ForegroundColor Cyan
    } else {
        Write-Host "  Suggested env-var-name: " -NoNewline -ForegroundColor DarkGray
        Write-Host $suggestedEnv -ForegroundColor Cyan
        
        $input = Read-Host "  Enter env var name (Enter=suggested, 's'=skip)"
        
        if ($input -eq 's') {
            Write-Warn "Skipped: $secretName"
            $skippedCount++
            continue
        }
        
        $envVarName = if ([string]::IsNullOrWhiteSpace($input)) { $suggestedEnv } else { $input }
        
        # Validate the env var name
        if ($envVarName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            Write-Err "Invalid env var name: '$envVarName' - skipping"
            $skippedCount++
            continue
        }
    }
    
    # Get resource (use existing if present)
    $resource = $null
    if ($secret.HasResource) {
        $resource = $secret.ExistingResource
        Write-Host "  resource: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$resource (existing)" -ForegroundColor Cyan
    } else {
        Write-Host "  Suggested resource: " -NoNewline -ForegroundColor DarkGray
        Write-Host $suggestedRes -ForegroundColor Cyan
        
        $input = Read-Host "  Enter resource name (Enter=suggested, 's'=skip)"
        
        if ($input -eq 's') {
            Write-Warn "Skipped: $secretName"
            $skippedCount++
            continue
        }
        
        $resource = if ([string]::IsNullOrWhiteSpace($input)) { $suggestedRes } else { $input }
        
        # Validate the resource name
        if ($resource -notmatch '^[a-zA-Z][a-zA-Z0-9-]*$') {
            Write-Err "Invalid resource name: '$resource' - skipping"
            $skippedCount++
            continue
        }
    }
    
    # Update the secret's tags
    try {
        az keyvault secret set-attributes `
            --vault-name $settings.vaultName `
            --name $secretName `
            --tags "resource=$resource" "env-var-name=$envVarName" | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "$secretName -> resource=$resource, env-var-name=$envVarName"
            $migratedCount++
        } else {
            Write-Err "Failed to update: $secretName"
            $failedCount++
        }
    } catch {
        Write-Err "Error updating $secretName : $_"
        $failedCount++
    }
}

# Summary
Write-Host "`n+==============================================================+" -ForegroundColor Green
Write-Host "|                    Migration Complete                        |" -ForegroundColor Green
Write-Host "+==============================================================+`n" -ForegroundColor Green

Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "  Migrated: $migratedCount" -ForegroundColor Green
if ($skippedCount -gt 0) {
    Write-Host "  Skipped:  $skippedCount" -ForegroundColor Yellow
}
if ($failedCount -gt 0) {
    Write-Host "  Failed:   $failedCount" -ForegroundColor Red
}
Write-Host ""
