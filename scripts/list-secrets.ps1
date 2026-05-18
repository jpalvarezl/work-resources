#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List all secrets in the Azure KeyVault.

.DESCRIPTION
    Displays all secrets from KeyVault, grouped by resource and then by flavor
    (when flavors are present). Shows the environment variable name from the
    'env-var-name' tag.

.PARAMETER Resource
    Optional: Filter by resource tag. Single value or comma-separated list,
    e.g. -Resource "myapi" or -Resource "myapi,shared". When omitted, all
    resources are shown.

.PARAMETER Flavor
    Optional: Filter by flavor tag. Single value or comma-separated list,
    e.g. -Flavor "py" or -Flavor "py,js". When omitted, all flavors are shown
    and grouped under each resource.

.EXAMPLE
    ./list-secrets.ps1
    Shows all secrets from KeyVault grouped by resource and flavor.

.EXAMPLE
    ./list-secrets.ps1 -Resource myapp
    Shows only secrets with resource tag 'myapp'.

.EXAMPLE
    ./list-secrets.ps1 -Resource "myapp,shared"
    Shows secrets for both 'myapp' and 'shared' resources.

.EXAMPLE
    ./list-secrets.ps1 -Resource foundry-sdk-deployment -Flavor py
    Shows only secrets where resource='foundry-sdk-deployment' AND flavor='py'.

.EXAMPLE
    ./list-secrets.ps1 -Resource foundry-sdk-deployment -Flavor py -Name foundry-project-endpoint
    Shows exactly one secret: the one whose KV name is
    'foundry-sdk-deployment-py-foundry-project-endpoint'.
#>

param(
    [string]$Resource,

    [string]$Flavor,

    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Name
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

# Parse and validate -Name / -Resource / -Flavor BEFORE any network call so
# misuse fails fast without authenticating to Azure.
$resourceFilters = @()
if (-not [string]::IsNullOrWhiteSpace($Resource)) {
    $resourceFilters = @($Resource -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$flavorFilters = @()
if (-not [string]::IsNullOrWhiteSpace($Flavor)) {
    $flavorFilters = @($Flavor -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$nameFilter = Resolve-NameFilter -Name $Name -ResourceFilters $resourceFilters -FlavorFilters $flavorFilters

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

# Apply filters via the shared helper, plus exact-name match when -Name was supplied
$secretsList = $secretsList | Where-Object {
    if (-not (Test-SecretTagsMatchFilter -Tags $_.tags -ResourceFilters $resourceFilters -FlavorFilters $flavorFilters)) {
        return $false
    }
    if ($nameFilter -and $_.name -ne $nameFilter) {
        return $false
    }
    return $true
}

if ($null -eq $secretsList -or @($secretsList).Count -eq 0) {
    $filterDesc = @()
    if ($resourceFilters.Count -gt 0) { $filterDesc += "resource=$($resourceFilters -join ',')" }
    if ($flavorFilters.Count -gt 0)   { $filterDesc += "flavor=$($flavorFilters -join ',')" }
    if ($nameFilter)                  { $filterDesc += "name=$nameFilter" }
    $filterText = if ($filterDesc.Count -gt 0) { " matching $($filterDesc -join ' AND ')" } else { "" }
    Write-Host "`n  No secrets found$filterText." -ForegroundColor Red
    Write-Host "  Run wr-list without filters to see all secrets.`n" -ForegroundColor DarkGray
    exit 1
}

# Group secrets by resource tag, then by flavor tag (within each resource)
$secretsByResource = @{}

foreach ($secret in $secretsList) {
    $secretName = $secret.name

    # Resource bucket
    $resName = "(untagged)"
    if ($secret.tags -and $secret.tags.resource) {
        $resName = $secret.tags.resource
    }

    if (-not $secretsByResource.ContainsKey($resName)) {
        $secretsByResource[$resName] = @{}
    }

    # Flavor sub-bucket inside the resource
    $flvName = "(unflavored)"
    if ($secret.tags -and $secret.tags.flavor) {
        $flvName = $secret.tags.flavor
    }

    if (-not $secretsByResource[$resName].ContainsKey($flvName)) {
        $secretsByResource[$resName][$flvName] = @()
    }

    $envVarName = $null
    if ($secret.tags -and $secret.tags."env-var-name") {
        $envVarName = $secret.tags."env-var-name"
    }

    $secretsByResource[$resName][$flvName] += @{
        Name = $secretName
        EnvVarName = $envVarName
    }
}

# Display: resource -> flavor -> secrets
$totalSecrets = 0
$missingTagCount = 0

foreach ($resName in ($secretsByResource.Keys | Sort-Object)) {
    Write-Host "`n+-- " -ForegroundColor DarkGray -NoNewline
    Write-Host $resName -ForegroundColor Yellow

    $flavorMap = $secretsByResource[$resName]
    $flavorNames = $flavorMap.Keys | Sort-Object
    # Skip the flavor sub-grouping when there's only one (unflavored) bucket —
    # this preserves the original flat look for legacy/unflavored resources.
    $showFlavorHeaders = -not (($flavorNames.Count -eq 1) -and ($flavorNames[0] -eq "(unflavored)"))

    foreach ($flvName in $flavorNames) {
        $secretList = @($flavorMap[$flvName])

        if ($showFlavorHeaders) {
            Write-Host "|  +-- " -ForegroundColor DarkGray -NoNewline
            Write-Host "[$flvName]" -ForegroundColor Magenta
        }

        for ($i = 0; $i -lt $secretList.Count; $i++) {
            $secret = $secretList[$i]
            $isLast = ($i -eq $secretList.Count - 1)

            if ($showFlavorHeaders) {
                $prefix = if ($isLast) { "|     +--" } else { "|     |--" }
            } else {
                $prefix = if ($isLast) { "+--" } else { "|--" }
            }

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
}

# Summary
$resCount = $secretsByResource.Keys.Count
$flvCount = ($secretsByResource.Values | ForEach-Object { $_.Keys } | Sort-Object -Unique).Count
Write-Host "`n-----------------------------------------" -ForegroundColor DarkGray
Write-Host "Total: $totalSecrets secret(s) in $resCount resource(s), $flvCount flavor(s)" -ForegroundColor DarkGray

if ($missingTagCount -gt 0) {
    Write-Host "  [!] $missingTagCount secret(s) missing 'env-var-name' tag" -ForegroundColor Yellow
    Write-Host "      Run: wr-migrate to add tags" -ForegroundColor DarkGray
}

Write-Host ""
