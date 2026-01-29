#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear loaded secrets from the current session.

.DESCRIPTION
    Removes environment variables that were loaded by load-env.ps1.
    Reads from resources.json to determine which variables to clear.

.PARAMETER Resource
    Clear only secrets for a specific resource. If not specified, clears all.

.PARAMETER All
    Clear all secrets from all resources.

.PARAMETER Export
    Output shell-compatible unset commands instead of clearing vars in PowerShell.
    Supported values: fish, bash, zsh, powershell
    
    Usage for bash:   eval "$(pwsh ./scripts/clear-env.ps1 -Export bash -Force)"

.EXAMPLE
    ./clear-env.ps1
    Clears all loaded secrets (prompts for confirmation).

.EXAMPLE
    ./clear-env.ps1 -Resource myapp
    Clears only secrets from the 'myapp' resource.

.EXAMPLE
    ./clear-env.ps1 -All -Force
    Clears all secrets without confirmation prompt.
#>

param(
    [string]$Resource,
    [switch]$All,
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
$ConfigRoot = Join-Path $ProjectRoot "config"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Get-ResourcesConfig {
    $resourcesPath = Join-Path $ConfigRoot "resources.json"
    if (-not (Test-Path $resourcesPath)) {
        throw "Resources file not found. Run setup.ps1 first."
    }
    return Get-Content $resourcesPath -Raw | ConvertFrom-Json
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
$resourcesConfig = Get-ResourcesConfig

# Determine which resources to clear
$resourceNames = $resourcesConfig.resources.PSObject.Properties.Name

if ($resourceNames.Count -eq 0) {
    if (-not $SilentMode) {
        Write-Host "`n  No resources configured." -ForegroundColor Yellow
    }
    exit 0
}

# Filter by resource if specified
if (-not [string]::IsNullOrWhiteSpace($Resource)) {
    if ($Resource -notin $resourceNames) {
        if (-not $SilentMode) {
            Write-Host "`n  Resource '$Resource' not found." -ForegroundColor Red
            Write-Host "  Available: $($resourceNames -join ', ')`n" -ForegroundColor DarkGray
        }
        exit 1
    }
    $resourceNames = @($Resource)
}

# Collect all env vars to clear
$envVarsToClear = @()
foreach ($resName in $resourceNames) {
    $resourceData = $resourcesConfig.resources.$resName
    foreach ($prop in $resourceData.secrets.PSObject.Properties) {
        $envVarName = $prop.Value
        if ($envVarName -notin $envVarsToClear) {
            $envVarsToClear += $envVarName
        }
    }
}

if ($envVarsToClear.Count -eq 0) {
    if (-not $SilentMode) {
        Write-Host "`n  No environment variables to clear." -ForegroundColor Yellow
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
