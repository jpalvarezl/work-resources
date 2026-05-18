#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear loaded secrets from the current session.

.DESCRIPTION
    Removes environment variables that were loaded by load-env.ps1.
    Queries KeyVault to determine which variables to clear based on
    the 'env-var-name' tags.

.PARAMETER Resource
    Clear only secrets for a specific resource prefix. If not specified, clears all.

.PARAMETER Flavor
    Optional: Restrict which env vars to clear to those tagged with the given
    flavor(s). Single value or comma-separated list. Note: this narrows the
    KeyVault-defined env var names to consider; it does not verify which
    flavor actually populated a given env var in the current session (the OS
    does not retain that provenance).

.PARAMETER Name
    Optional: Narrow to the single env var that the secret named
    `{Resource}-{Name}` (or `{Resource}-{Flavor}-{Name}` when `-Flavor` is set)
    maps to. Requires `-Resource` and accepts at most one `-Resource` / one
    `-Flavor`. Passing an empty string is treated the same as omitting `-Name`.

.PARAMETER Force
    Skip confirmation prompt.

.PARAMETER Export
    Output shell-compatible unset commands instead of clearing vars in PowerShell.
    Supported values: fish, bash, zsh, powershell
    
    Usage for bash:   eval "$(pwsh ./scripts/clear-env.ps1 -Export bash -Force)"

.PARAMETER NoEnvFile
    Disable the default behaviour of also removing the wr-managed fenced
    block from `./.env` in the current working directory. By default, this
    script removes that block (in addition to unsetting in-process env
    vars) so that the on-disk file and the in-process state stay in sync.
    The block is removed regardless of whether any in-process env vars
    were found (fresh-shell case) and regardless of `-Export` mode (so
    the eval-and-unset workflow doesn't leave the .env block stranded).
    Pass `-NoEnvFile` to leave `./.env` untouched.

.EXAMPLE
    ./clear-env.ps1
    Clears all loaded secrets (prompts for confirmation).

.EXAMPLE
    ./clear-env.ps1 -Resource myapp
    Clears only env vars whose KV secrets are tagged resource='myapp'.

.EXAMPLE
    ./clear-env.ps1 -Resource foundry-sdk-deployment -Flavor py
    Clears only env vars whose secrets are tagged resource='foundry-sdk-deployment' AND flavor='py'.

.EXAMPLE
    ./clear-env.ps1 -Resource foundry-sdk-deployment -Flavor py -Name foundry-project-endpoint -Force
    Clears exactly the env var that the single secret
    'foundry-sdk-deployment-py-foundry-project-endpoint' maps to.

.EXAMPLE
    ./clear-env.ps1 -Force
    Clears all secrets without confirmation prompt.
#>

param(
    [string]$Resource,
    [string]$Flavor,
    [ValidatePattern('^([a-zA-Z][a-zA-Z0-9-]*)?$')]
    [string]$Name,
    [switch]$Force,
    [ValidateSet("fish", "bash", "zsh", "powershell", "")]
    [string]$Export = "",
    [switch]$NoEnvFile
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
        az login | Out-Null
        $account = az account show | ConvertFrom-Json
    }
    return $account
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

# In Export mode, suppress all interactive output
$SilentMode = -not [string]::IsNullOrEmpty($Export)

if (-not $SilentMode) {
    Write-Host "`n[CLEAR] Clear Environment Variables" -ForegroundColor Magenta
}

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

# Authenticate with Azure (silently in Export mode)
if (-not $SilentMode) {
    Write-Host "`nVerifying Azure authentication..." -ForegroundColor DarkGray
}
$account = Test-AzureLogin

# List all secrets from KeyVault with their tags
$secretsList = az keyvault secret list --vault-name $settings.vaultName --query "[].{name:name, tags:tags}" -o json 2>$null | ConvertFrom-Json

if ($null -eq $secretsList -or $secretsList.Count -eq 0) {
    if (-not $SilentMode) {
        Write-Host "`n  No secrets in vault." -ForegroundColor Yellow
    }
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
    if (-not $SilentMode) {
        $filterDesc = @()
        if ($resourceFilters.Count -gt 0) { $filterDesc += "resource=$($resourceFilters -join ',')" }
        if ($flavorFilters.Count -gt 0)   { $filterDesc += "flavor=$($flavorFilters -join ',')" }
        if ($nameFilter)                  { $filterDesc += "name=$nameFilter" }
        $filterText = if ($filterDesc.Count -gt 0) { " matching $($filterDesc -join ' AND ')" } else { "" }
        Write-Host "`n  No secrets found$filterText." -ForegroundColor Red
    }
    exit 1
}

# Remove the wr-managed block from ./.env BEFORE any later early-exit can
# skip it. This is the agent-harness scenario the PR is designed for:
# wr-load wrote ./.env in a previous tool call, the in-process env vars
# vanished when that shell exited, and now wr-clear from a fresh shell
# must still be able to remove the on-disk block. Runs in -Export mode
# too (symmetry with wr-load -Export which always writes ./.env).
if (-not $NoEnvFile) {
    $envFilePath = Join-Path (Get-Location).Path '.env'
    try {
        if (Remove-EnvFileBlock -Path $envFilePath) {
            if (-not $SilentMode) {
                Write-Host "  [OK] Removed work-resources block from $envFilePath" -ForegroundColor Green
            }
        }
    } catch {
        if (-not $SilentMode) {
            Write-Host "  [!] Failed to update $envFilePath : $_" -ForegroundColor Yellow
        }
    }
}

# Collect all env vars to clear from tags
$envVarsToClear = @()
foreach ($secret in $secretsList) {
    if ($secret.tags -and $secret.tags."env-var-name") {
        $envVarName = $secret.tags."env-var-name"
        if ($envVarName -notin $envVarsToClear) {
            $envVarsToClear += $envVarName
        }
    }
}

if ($envVarsToClear.Count -eq 0) {
    if (-not $SilentMode) {
        Write-Host "`n  No environment variables to clear (secrets missing 'env-var-name' tag)." -ForegroundColor Yellow
    }
    exit 0
}

# Check which are actually set
$setVars = @()
$notSetVars = @()
foreach ($var in $envVarsToClear) {
    $value = [Environment]::GetEnvironmentVariable($var, "Process")
    if ($null -ne $value) {
        $setVars += $var
    } else {
        $notSetVars += $var
    }
}

if ($setVars.Count -eq 0) {
    if (-not $SilentMode) {
        Write-Host "`n  No secrets currently loaded in this session." -ForegroundColor Yellow
        Write-Host "  ($($envVarsToClear.Count) configured env vars are not set)`n" -ForegroundColor DarkGray
    }
    exit 0
}

# Show what will be cleared (only in interactive mode)
if (-not $SilentMode) {
    Write-Host "`nEnvironment variables to clear:" -ForegroundColor Yellow
    foreach ($var in $setVars) {
        Write-Host "  * $var" -ForegroundColor White
    }

    if ($notSetVars.Count -gt 0) {
        Write-Host "`nNot currently set (skipping):" -ForegroundColor DarkGray
        foreach ($var in $notSetVars) {
            Write-Host "  * $var" -ForegroundColor DarkGray
        }
    }
}

# Confirm unless -Force or -Export (non-interactive)
if (-not $Force -and [string]::IsNullOrEmpty($Export)) {
    Write-Host ""
    $confirm = Read-Host "Clear $($setVars.Count) variable(s)? [y/N]"
    if ($confirm -notmatch '^[yY]') {
        Write-Host "`nCancelled.`n" -ForegroundColor Yellow
        exit 0
    }
}

# Clear the variables
$cleared = 0

# If Export mode, output shell commands for ALL configured vars (we can't check parent shell)
if (-not [string]::IsNullOrEmpty($Export)) {
    foreach ($var in $envVarsToClear) {
        switch ($Export) {
            "fish" {
                Write-Output "set -e $var;"
            }
            { $_ -in "bash", "zsh" } {
                Write-Output "unset $var;"
            }
            "powershell" {
                Write-Output "Remove-Item Env:\$var -ErrorAction SilentlyContinue;"
            }
        }
        $cleared++
    }
} else {
    foreach ($var in $setVars) {
        [Environment]::SetEnvironmentVariable($var, $null, "Process")
        $cleared++
        Write-Host "  [OK] Cleared `$env:$var" -ForegroundColor Green
    }
    Write-Host "`n[SUCCESS] Cleared $cleared environment variable(s) from current session.`n" -ForegroundColor Green
}
