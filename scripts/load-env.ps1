#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Load secrets from Azure KeyVault into environment variables.

.DESCRIPTION
    Loads secrets from KeyVault and sets them as environment variables in the 
    current session. The environment variable name is read from the 'env-var-name' 
    tag stored on each secret in KeyVault.

.PARAMETER Resource
    Optional: Filter by resource prefix. Can be:
    - Single: -Resource "resourceA"
    - Multiple: -Resource "resourceA,resourceB"
    - All (default if omitted): loads all secrets from the vault

.PARAMETER Flavor
    Optional: Filter by flavor tag. Can be a single value or comma-separated
    list, e.g. -Flavor "py" or -Flavor "py,js". When omitted, secrets are not
    filtered by flavor (legacy secrets without a flavor tag remain included).
    When specified, only secrets whose 'flavor' tag matches one of the requested
    flavors are loaded; legacy untagged secrets are excluded.

.PARAMETER Export
    Output shell-compatible export commands instead of setting vars in PowerShell.
    Supported values: fish, bash, zsh, powershell
    
    Usage for fish:   eval (pwsh ./scripts/load-env.ps1 -Resource myapp -Export fish)
    Usage for bash:   eval "$(pwsh ./scripts/load-env.ps1 -Resource myapp -Export bash)"

.PARAMETER SpawnShell
    Instead of modifying current session, spawn a new shell with secrets loaded.
    Exit the spawned shell to return to a clean session.

.EXAMPLE
    ./load-env.ps1
    Loads all secrets from KeyVault into current PowerShell session.

.EXAMPLE
    ./load-env.ps1 -Resource myapp
    Loads secrets with resource tag 'myapp' into current session.

.EXAMPLE
    ./load-env.ps1 -Resource foundry-sdk-deployment -Flavor py
    Loads only secrets whose resource='foundry-sdk-deployment' AND flavor='py'.

.EXAMPLE
    eval (pwsh ./scripts/load-env.ps1 -Resource myapp -Export fish)
    Loads secrets into your fish shell session.

.EXAMPLE
    ./load-env.ps1 -Resource "myapp,shared"
    Loads secrets for both 'myapp' and 'shared' resource prefixes.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Resource,

    [Parameter(Mandatory = $false)]
    [string]$Flavor,
    
    [ValidateSet("fish", "bash", "zsh", "powershell", "")]
    [string]$Export = "",
    
    [switch]$SpawnShell
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

# Write to stderr so messages don't interfere with export commands sent to stdout
function Write-Stderr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Write-Step {
    param([string]$Message)
    Write-Stderr "`n>> $Message"
}

function Write-Success {
    param([string]$Message)
    Write-Stderr "  [OK] $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Stderr "  [i] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Stderr "  [!] $Message"
}

function Write-Err {
    param([string]$Message)
    Write-Stderr "  [X] $Message"
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

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

Write-Stderr "`n[KEY] Loading KeyVault Secrets"

# Check Azure login
Write-Step "Verifying Azure authentication..."

$account = Test-AzureLogin

Write-Success "Logged in as: $($account.user.name)"

# Load configuration
$settings = Get-Settings

Write-Step "Loading secrets from vault: $($settings.vaultName)"

# Parse resource filter (if provided)
$resourceFilters = @()
if (-not [string]::IsNullOrWhiteSpace($Resource)) {
    $resourceFilters = @($Resource -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Info "Filtering by resource(s): $($resourceFilters -join ', ')"
}

# Parse flavor filter (if provided)
$flavorFilters = @()
if (-not [string]::IsNullOrWhiteSpace($Flavor)) {
    $flavorFilters = @($Flavor -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Info "Filtering by flavor(s): $($flavorFilters -join ', ')"
}

# List all secrets from KeyVault with their tags
$secretsList = az keyvault secret list --vault-name $settings.vaultName --query "[].{name:name, tags:tags}" -o json 2>$null | ConvertFrom-Json

if ($null -eq $secretsList -or $secretsList.Count -eq 0) {
    Write-Warn "No secrets found in vault."
    Write-Stderr "  Add secrets using: wr-save -Resource <name> -Name <secret-name> -EnvVarName <ENV_VAR>"
    exit 0
}

# Filter secrets by resource + flavor tags
$secretsToLoad = @()
$secretNameToTags = @{}
foreach ($secret in $secretsList) {
    if (Test-SecretTagsMatchFilter -Tags $secret.tags -ResourceFilters $resourceFilters -FlavorFilters $flavorFilters) {
        $secretsToLoad += $secret.name
        $secretNameToTags[$secret.name] = $secret.tags
    }
}

if ($secretsToLoad.Count -eq 0) {
    Write-Warn "No secrets found matching the specified filter(s)."
    Write-Stderr "  Use wr-list to see available secrets, resources, and flavors."
    exit 0
}

if ($resourceFilters.Count -gt 1) {
    Write-Warn "Loading from multiple resources - secrets with colliding environment variable names will be overwritten."
}

# Pre-flight collision detection: same env-var-name across multiple flavors/secrets
# will overwrite each other in the resulting environment. Warn explicitly so the
# user can disambiguate with -Flavor if needed.
$envVarNameToSecrets = @{}
foreach ($secretName in $secretsToLoad) {
    $tags = $secretNameToTags[$secretName]
    if ($tags -and $tags.'env-var-name') {
        $evn = $tags.'env-var-name'
        if (-not $envVarNameToSecrets.ContainsKey($evn)) {
            $envVarNameToSecrets[$evn] = @()
        }
        $envVarNameToSecrets[$evn] += $secretName
    }
}
foreach ($evn in $envVarNameToSecrets.Keys) {
    $secrets = $envVarNameToSecrets[$evn]
    if ($secrets.Count -gt 1) {
        Write-Warn "Multiple secrets map to `$env:$evn (last loaded wins):"
        foreach ($s in $secrets) {
            $flv = $secretNameToTags[$s].'flavor'
            $flvLabel = if ($flv) { "[flavor=$flv]" } else { "[no flavor]" }
            Write-Stderr ("       - {0} {1}" -f $s, $flvLabel)
        }
        Write-Stderr "       Use -Flavor to disambiguate."
    }
}

# Fetch secrets from KeyVault
Write-Step "Fetching $($secretsToLoad.Count) secret(s) from KeyVault..."

$loadedSecrets = @{}
$failedSecrets = @()
$missingTagSecrets = @()
$current = 0
$total = $secretsToLoad.Count

foreach ($secretName in $secretsToLoad) {
    $current++
    
    $percentComplete = [math]::Round(($current / $total) * 100)
    Write-Progress -Activity "Loading secrets" -Status "$secretName" -PercentComplete $percentComplete
    
    try {
        # Fetch secret with its tags
        $secretData = az keyvault secret show `
            --vault-name $settings.vaultName `
            --name $secretName `
            --query "{value:value, tags:tags}" -o json 2>$null | ConvertFrom-Json
        
        if ($LASTEXITCODE -ne 0 -or $null -eq $secretData) {
            $failedSecrets += $secretName
            Write-Err "$secretName (failed to fetch)"
            continue
        }
        
        # Get env var name from tag
        $envVarName = $null
        if ($secretData.tags -and $secretData.tags."env-var-name") {
            $envVarName = $secretData.tags."env-var-name"
        }
        
        if ([string]::IsNullOrWhiteSpace($envVarName)) {
            $missingTagSecrets += $secretName
            Write-Err "$secretName (missing 'env-var-name' tag - run wr-migrate to fix)"
            continue
        }
        
        $loadedSecrets[$envVarName] = $secretData.value
        Write-Stderr "  [OK] $secretName -> `$env:$envVarName"
        
    } catch {
        $failedSecrets += $secretName
        Write-Err "$secretName (error: $_)"
    }
}

Write-Progress -Activity "Loading secrets" -Completed

if ($loadedSecrets.Count -eq 0) {
    Write-Stderr "`n[ERROR] No secrets were loaded."
    if ($missingTagSecrets.Count -gt 0) {
        Write-Stderr "  $($missingTagSecrets.Count) secret(s) are missing the 'env-var-name' tag."
        Write-Stderr "  Run: wr-migrate to add tags."
    }
    exit 1
}

# Output or set environment variables based on mode
if ($Export) {
    # Output shell-compatible export commands
    Write-Stderr "`n[SUCCESS] Loaded $($loadedSecrets.Count) secret(s)"
    if ($failedSecrets.Count -gt 0) {
        Write-Warn "$($failedSecrets.Count) secret(s) failed to load"
    }
    if ($missingTagSecrets.Count -gt 0) {
        Write-Warn "$($missingTagSecrets.Count) secret(s) missing 'env-var-name' tag"
    }
    
    foreach ($entry in $loadedSecrets.GetEnumerator()) {
        $name = $entry.Key
        $value = ConvertTo-ShellEscapedSingleQuoted -Value $entry.Value -Shell $Export

        switch ($Export) {
            "fish" {
                Write-Output "set -gx $name '$value';"
            }
            "bash" {
                Write-Output "export $name='$value';"
            }
            "zsh" {
                Write-Output "export $name='$value';"
            }
            "powershell" {
                Write-Output "`$env:$name = '$value';"
            }
        }
    }
} elseif ($SpawnShell) {
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
    if ($missingTagSecrets.Count -gt 0) {
        Write-Warn "$($missingTagSecrets.Count) secret(s) missing 'env-var-name' tag - run wr-migrate to fix"
    }
    
    Write-Host "`nTip: Use wr-clear to remove loaded secrets from session`n" -ForegroundColor DarkGray
}
