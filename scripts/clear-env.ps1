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

.PARAMETER Force
    Skip confirmation prompt.

.PARAMETER Export
    Output shell-compatible unset commands instead of clearing vars in PowerShell.
    Supported values: fish, bash, zsh, powershell
    
    Usage for bash:   eval "$(pwsh ./scripts/clear-env.ps1 -Export bash -Force)"

.EXAMPLE
    ./clear-env.ps1
    Clears all loaded secrets (prompts for confirmation).

.EXAMPLE
    ./clear-env.ps1 -Resource myapp
    Clears only secrets with names starting with 'myapp-'.

.EXAMPLE
    ./clear-env.ps1 -Force
    Clears all secrets without confirmation prompt.
#>

param(
    [string]$Resource,
    [switch]$Force,
    [ValidateSet("fish", "bash", "zsh", "powershell", "")]
    [string]$Export = ""
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

# Filter by resource tag if specified
if (-not [string]::IsNullOrWhiteSpace($Resource)) {
    $secretsList = $secretsList | Where-Object { $_.tags -and $_.tags.resource -eq $Resource }
    if ($secretsList.Count -eq 0) {
        if (-not $SilentMode) {
            Write-Host "`n  No secrets found with resource tag '$Resource'." -ForegroundColor Red
        }
        exit 1
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
