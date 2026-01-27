#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Load secrets from Azure KeyVault into environment variables.

.DESCRIPTION
    Loads secrets for specified resource(s) from KeyVault and sets them as
    environment variables in the current session. Uses ACCUMULATE mode by
    default - loading multiple resources adds to existing vars.

.PARAMETER Resource
    Resource name(s) to load. Can be:
    - Single: -Resource "resourceA"
    - Multiple: -Resource "resourceA,resourceB"
    - All: -Resource "all"

.PARAMETER SpawnShell
    Instead of modifying current session, spawn a new shell with secrets loaded.
    Exit the spawned shell to return to a clean session.

.EXAMPLE
    ./load-env.ps1 -Resource myapp
    Loads all secrets for 'myapp' into current session.

.EXAMPLE
    ./load-env.ps1 -Resource "myapp,shared"
    Loads secrets for both 'myapp' and 'shared' resources.

.EXAMPLE
    ./load-env.ps1 -Resource all
    Loads all secrets from all resources.

.EXAMPLE
    ./load-env.ps1 -Resource myapp -SpawnShell
    Spawns a new shell with secrets loaded. Type 'exit' to return clean.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Resource,
    
    [switch]$SpawnShell
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$ConfigRoot = Join-Path (Split-Path $ScriptRoot -Parent) "config"

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
    $settingsPath = Join-Path $ConfigRoot "settings.json"
    if (-not (Test-Path $settingsPath)) {
        throw "Settings file not found. Run setup.ps1 first."
    }
    return Get-Content $settingsPath -Raw | ConvertFrom-Json
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
        Write-Info "Not logged in. Running 'az login'..."
        az login | Out-Null
        $account = az account show | ConvertFrom-Json
    }
    return $account
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

Write-Host "`n[KEY] Loading KeyVault Secrets" -ForegroundColor Magenta

# Check Azure login
Write-Step "Verifying Azure authentication..."
$account = Test-AzureLogin
Write-Success "Logged in as: $($account.user.name)"

# Load configuration
$settings = Get-Settings
$resourcesConfig = Get-ResourcesConfig

# Parse resource parameter
$resourceList = if ($Resource -eq "all") {
    $resourcesConfig.resources.PSObject.Properties.Name
} else {
    $Resource -split "," | ForEach-Object { $_.Trim() }
}

if ($resourceList.Count -eq 0) {
    Write-Warn "No resources found in configuration."
    Write-Host "  Add secrets using: ./save-secret.ps1 -Resource <name> -Name <secret-name>`n" -ForegroundColor DarkGray
    exit 0
}

Write-Step "Loading secrets from vault: $($settings.vaultName)"
Write-Info "Resources: $($resourceList -join ', ')"

# Collect all secrets to load
$secretsToLoad = @{}
$missingResources = @()

foreach ($res in $resourceList) {
    $resourceData = $resourcesConfig.resources.$res
    if (-not $resourceData) {
        $missingResources += $res
        continue
    }
    
    foreach ($prop in $resourceData.secrets.PSObject.Properties) {
        $secretName = $prop.Name      # KeyVault secret name (e.g., "myapp-api-key")
        $envVarName = $prop.Value     # Environment variable name (e.g., "MYAPP_API_KEY")
        $secretsToLoad[$secretName] = $envVarName
    }
}

if ($missingResources.Count -gt 0) {
    Write-Warn "Resources not found in config: $($missingResources -join ', ')"
}

if ($secretsToLoad.Count -eq 0) {
    Write-Warn "No secrets found for specified resources."
    exit 0
}

# Fetch secrets from KeyVault
Write-Step "Fetching $($secretsToLoad.Count) secret(s) from KeyVault..."

$loadedSecrets = @{}
$failedSecrets = @()
$current = 0
$total = $secretsToLoad.Count

foreach ($entry in $secretsToLoad.GetEnumerator()) {
    $current++
    $secretName = $entry.Key
    $envVarName = $entry.Value
    
    $percentComplete = [math]::Round(($current / $total) * 100)
    Write-Progress -Activity "Loading secrets" -Status "$secretName" -PercentComplete $percentComplete
    
    try {
        $value = az keyvault secret show `
            --vault-name $settings.vaultName `
            --name $secretName `
            --query "value" -o tsv 2>$null
        
        if ($LASTEXITCODE -eq 0 -and $value) {
            $loadedSecrets[$envVarName] = $value
            Write-Host "  [OK] " -ForegroundColor Green -NoNewline
            Write-Host "$secretName -> " -ForegroundColor DarkGray -NoNewline
            Write-Host "`$env:$envVarName" -ForegroundColor White
        } else {
            $failedSecrets += $secretName
            Write-Host "  [X] " -ForegroundColor Red -NoNewline
            Write-Host "$secretName (not found in vault)" -ForegroundColor DarkGray
        }
    } catch {
        $failedSecrets += $secretName
        Write-Host "  [X] " -ForegroundColor Red -NoNewline
        Write-Host "$secretName (error: $_)" -ForegroundColor DarkGray
    }
}

Write-Progress -Activity "Loading secrets" -Completed

if ($loadedSecrets.Count -eq 0) {
    Write-Host "`n[ERROR] No secrets were loaded." -ForegroundColor Red
    exit 1
}

# Set environment variables
if ($SpawnShell) {
    # Spawn new shell with secrets
    foreach ($entry in $loadedSecrets.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
    
    Write-Host "`n[LAUNCH] Spawning new shell with $($loadedSecrets.Count) secret(s) loaded..." -ForegroundColor Cyan
    Write-Host "   Type 'exit' to return to clean session`n" -ForegroundColor DarkGray
    
    # Try pwsh first, fall back to powershell
    $shellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    & $shellCmd -NoLogo -NoExit -Command {
        Write-Host "[KEY] KeyVault secrets loaded into this session" -ForegroundColor Green
    }
} else {
    # Set in current session
    foreach ($entry in $loadedSecrets.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
    
    Write-Host "`n[SUCCESS] Loaded $($loadedSecrets.Count) secret(s) into current session" -ForegroundColor Green
    
    if ($failedSecrets.Count -gt 0) {
        Write-Warn "$($failedSecrets.Count) secret(s) failed to load"
    }
    
    Write-Host "`nTip: Use ./clear-env.ps1 to remove loaded secrets from session`n" -ForegroundColor DarkGray
}
