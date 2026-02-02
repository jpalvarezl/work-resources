#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List all secrets in the Azure KeyVault.

.DESCRIPTION
    Displays all secrets from KeyVault, grouped by resource prefix.
    Shows the environment variable name from the 'env-var-name' tag.

.PARAMETER Resource
    Filter to show only secrets with a specific resource prefix.

.EXAMPLE
    ./list-secrets.ps1
    Shows all secrets from KeyVault grouped by resource prefix.

.EXAMPLE
    ./list-secrets.ps1 -Resource myapp
    Shows only secrets with names starting with 'myapp-'.
#>

param(
    [string]$Resource
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

function Get-Settings {
    return Get-EnvSettings -ProjectRoot $ProjectRoot
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

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

Write-Host "`n[LIST] KeyVault Secrets Inventory" -ForegroundColor Magenta

# Load configuration
$settings = Get-Settings

Write-Host "`nVault: " -ForegroundColor DarkGray -NoNewline
Write-Host $settings.vaultName -ForegroundColor Cyan

# Verify Azure login
Write-Host "`nVerifying Azure authentication..." -ForegroundColor DarkGray
$account = Test-AzureLogin
Write-Host "Logged in as: $($account.user.name)`n" -ForegroundColor DarkGray

# List all secrets from KeyVault with their tags
$secretsList = az keyvault secret list --vault-name $settings.vaultName --query "[].{name:name, tags:tags}" -o json 2>$null | ConvertFrom-Json

if ($null -eq $secretsList -or $secretsList.Count -eq 0) {
    Write-Host "`n  No secrets in vault." -ForegroundColor Yellow
    Write-Host "  Add secrets using: wr-save -Resource <name> -Name <secret-name> -EnvVarName <ENV_VAR>`n" -ForegroundColor DarkGray
    exit 0
}

# Filter by resource tag if specified
if (-not [string]::IsNullOrWhiteSpace($Resource)) {
    $secretsList = $secretsList | Where-Object { $_.tags -and $_.tags.resource -eq $Resource }
    if ($secretsList.Count -eq 0) {
        Write-Host "`n  No secrets found with resource tag '$Resource'." -ForegroundColor Red
        Write-Host "  Run wr-list without -Resource to see all secrets.`n" -ForegroundColor DarkGray
        exit 1
    }
}

# Group secrets by resource tag
$secretsByResource = @{}

foreach ($secret in $secretsList) {
    $secretName = $secret.name
    
    # Get resource from tag, default to "(untagged)" if missing
    $resource = "(untagged)"
    if ($secret.tags -and $secret.tags.resource) {
        $resource = $secret.tags.resource
    }
    
    if (-not $secretsByResource.ContainsKey($resource)) {
        $secretsByResource[$resource] = @()
    }
    
    $envVarName = $null
    if ($secret.tags -and $secret.tags."env-var-name") {
        $envVarName = $secret.tags."env-var-name"
    }
    
    $secretsByResource[$resource] += @{
        Name = $secretName
        EnvVarName = $envVarName
    }
}

# Display resources and secrets
$totalSecrets = 0
$missingTagCount = 0

foreach ($resName in ($secretsByResource.Keys | Sort-Object)) {
    $secrets = $secretsByResource[$resName]
    
    Write-Host "`n+-- " -ForegroundColor DarkGray -NoNewline
    Write-Host $resName -ForegroundColor Yellow
    
    $secretList = @($secrets)
    for ($i = 0; $i -lt $secretList.Count; $i++) {
        $secret = $secretList[$i]
        $isLast = ($i -eq $secretList.Count - 1)
        $prefix = if ($isLast) { "+--" } else { "|--" }
        
        $totalSecrets++
        
        Write-Host "$prefix " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($secret.Name)" -ForegroundColor White -NoNewline
        Write-Host " -> " -ForegroundColor DarkGray -NoNewline
        
        if ($secret.EnvVarName) {
            Write-Host "`$env:$($secret.EnvVarName)" -ForegroundColor Cyan
        } else {
            Write-Host "(no env-var-name tag)" -ForegroundColor Red
            $missingTagCount++
        }
    }
}

# Summary
Write-Host "`n-----------------------------------------" -ForegroundColor DarkGray
Write-Host "Total: $totalSecrets secret(s) in $($secretsByResource.Keys.Count) resource group(s)" -ForegroundColor DarkGray

if ($missingTagCount -gt 0) {
    Write-Host "  [!] $missingTagCount secret(s) missing 'env-var-name' tag" -ForegroundColor Yellow
    Write-Host "      Run: wr-migrate to add tags to existing secrets" -ForegroundColor DarkGray
}

Write-Host ""
