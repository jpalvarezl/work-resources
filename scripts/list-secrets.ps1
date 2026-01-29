#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List all resources and secrets configured in the project.

.DESCRIPTION
    Displays all resources and their associated secrets from the local
    configuration. Optionally verifies that secrets exist in the vault.

.PARAMETER Verify
    Check if each secret actually exists in KeyVault (requires Azure login).

.PARAMETER Resource
    Filter to show only a specific resource.

.EXAMPLE
    ./list-secrets.ps1
    Shows all resources and secrets from local config.

.EXAMPLE
    ./list-secrets.ps1 -Verify
    Shows all secrets and verifies each exists in KeyVault.

.EXAMPLE
    ./list-secrets.ps1 -Resource myapp
    Shows only secrets for the 'myapp' resource.
#>

param(
    [switch]$Verify,
    [string]$Resource
)

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

function Test-AzureLogin {
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Host "  [i] Not logged in. Running 'az login'..." -ForegroundColor DarkGray
        az login | Out-Null
        $account = az account show | ConvertFrom-Json
    }
    return $account
}

function Test-SecretExists {
    param([string]$VaultName, [string]$SecretName)
    
    $result = az keyvault secret show `
        --vault-name $VaultName `
        --name $SecretName `
        --query "name" -o tsv 2>$null
    
    return ($LASTEXITCODE -eq 0 -and $result)
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

Write-Host "`n[LIST] KeyVault Secrets Inventory" -ForegroundColor Magenta

# Load configuration
$settings = Get-Settings
$resourcesConfig = Get-ResourcesConfig

Write-Host "`nVault: " -ForegroundColor DarkGray -NoNewline
Write-Host $settings.vaultName -ForegroundColor Cyan

# Verify Azure login if needed
if ($Verify) {
    Write-Host "`nVerifying against KeyVault..." -ForegroundColor DarkGray
    $account = Test-AzureLogin
    Write-Host "Logged in as: $($account.user.name)`n" -ForegroundColor DarkGray
}

# Get resource list
$resourceNames = $resourcesConfig.resources.PSObject.Properties.Name

if ($resourceNames.Count -eq 0) {
    Write-Host "`n  No resources configured yet." -ForegroundColor Yellow
    Write-Host "  Add secrets using: ./save-secret.ps1 -Resource <name> -Name <secret-name>`n" -ForegroundColor DarkGray
    exit 0
}

# Filter if resource specified
if (-not [string]::IsNullOrWhiteSpace($Resource)) {
    if ($Resource -notin $resourceNames) {
        Write-Host "`n  Resource '$Resource' not found in configuration." -ForegroundColor Red
        Write-Host "  Available resources: $($resourceNames -join ', ')`n" -ForegroundColor DarkGray
        exit 1
    }
    $resourceNames = @($Resource)
}

# Display resources and secrets
$totalSecrets = 0
$verifiedSecrets = 0
$missingSecrets = 0

foreach ($resName in $resourceNames) {
    $resourceData = $resourcesConfig.resources.$resName
    
    Write-Host "`n+-- " -ForegroundColor DarkGray -NoNewline
    Write-Host $resName -ForegroundColor Yellow -NoNewline
    
    if (-not [string]::IsNullOrWhiteSpace($resourceData.description)) {
        Write-Host " - $($resourceData.description)" -ForegroundColor DarkGray -NoNewline
    }
    Write-Host ""
    
    $secrets = $resourceData.secrets.PSObject.Properties
    
    if ($secrets.Count -eq 0) {
        Write-Host "|   (no secrets)" -ForegroundColor DarkGray
        continue
    }
    
    $secretList = @($secrets)
    for ($i = 0; $i -lt $secretList.Count; $i++) {
        $secret = $secretList[$i]
        $isLast = ($i -eq $secretList.Count - 1)
        $prefix = if ($isLast) { "+--" } else { "|--" }
        
        $totalSecrets++
        
        Write-Host "$prefix " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($secret.Name)" -ForegroundColor White -NoNewline
        Write-Host " -> " -ForegroundColor DarkGray -NoNewline
        Write-Host "`$env:$($secret.Value)" -ForegroundColor Cyan -NoNewline
        
        if ($Verify) {
            $exists = Test-SecretExists -VaultName $settings.vaultName -SecretName $secret.Name
            if ($exists) {
                Write-Host " [OK]" -ForegroundColor Green -NoNewline
                $verifiedSecrets++
            } else {
                Write-Host " [X] (not in vault)" -ForegroundColor Red -NoNewline
                $missingSecrets++
            }
        }
        
        Write-Host ""
    }
}

# Summary
Write-Host "`n-----------------------------------------" -ForegroundColor DarkGray
Write-Host "Total: $totalSecrets secret(s) in $($resourceNames.Count) resource(s)" -ForegroundColor DarkGray

if ($Verify) {
    if ($missingSecrets -gt 0) {
        Write-Host "  [OK] Verified: $verifiedSecrets" -ForegroundColor Green
        Write-Host "  [X] Missing:  $missingSecrets" -ForegroundColor Red
    } else {
        Write-Host "  [OK] All secrets verified in KeyVault" -ForegroundColor Green
    }
}

Write-Host ""
