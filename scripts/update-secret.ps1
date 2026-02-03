#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Update an existing secret in Azure KeyVault.

.DESCRIPTION
    Updates an existing secret in KeyVault and sets the new value in the current
    shell session. The -Name parameter is the actual KeyVault secret name.
    -EnvVarName is optional - existing tag is preserved if not provided.

.PARAMETER Resource
    The resource tag to filter by (e.g., "azure-agents", "myapp").
    Required to identify which secret to update when names might overlap.

.PARAMETER Name
    The actual secret name in KeyVault (e.g., "azure-agents-endpoint", "myapp-api-key").

.PARAMETER Value
    Optional: The new secret value. If not provided, prompts interactively (recommended).

.PARAMETER EnvVarName
    Optional: Update the environment variable name tag. If not provided, keeps the existing tag.

.PARAMETER Export
    Output shell-compatible export commands instead of setting vars in PowerShell.
    Supported values: fish, bash, zsh, powershell
    
    Usage for fish:   eval (pwsh ./scripts/update-secret.ps1 -Resource azure-agents -Name azure-agents-endpoint -Export fish)
    Usage for bash:   eval "$(pwsh ./scripts/update-secret.ps1 -Resource azure-agents -Name azure-agents-endpoint -Export bash)"

.EXAMPLE
    ./update-secret.ps1 -Resource azure-agents -Name azure-agents-endpoint
    Prompts for the new value, keeps existing tags, updates current session.

.EXAMPLE
    ./update-secret.ps1 -Resource azure-agents -Name azure-agents-endpoint -Value "new-secret-value"
    Updates value directly (less secure, appears in shell history).

.EXAMPLE
    ./update-secret.ps1 -Resource myapp -Name myapp-api-key -EnvVarName "NEW_ENV_VAR"
    Updates the env var name tag, prompts for a new value.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Resource,
    
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Name,
    
    [string]$Value,
    
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
    [string]$EnvVarName,
    
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

function Read-SecureValue {
    param([string]$Prompt)
    
    # Write prompt to stderr
    [Console]::Error.Write($Prompt)
    
    # Cross-platform secure input
    if ($PSVersionTable.Platform -eq 'Unix') {
        # macOS/Linux: Use stty to hide input
        $value = ""
        try {
            # Disable echo
            stty -echo 2>$null
            $value = Read-Host
        } finally {
            # Re-enable echo
            stty echo 2>$null
            [Console]::Error.WriteLine("")  # New line after hidden input
        }
        return $value
    } else {
        # Windows: Use SecureString
        $secure = Read-Host -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

Write-Stderr "`n[KEY] Update Secret in KeyVault"

# Check Azure login
Write-Step "Verifying Azure authentication..."
$account = Test-AzureLogin
Write-Success "Logged in as: $($account.user.name)"

# Load configuration
$settings = Get-Settings

# Use the Name parameter directly as the secret name (no concatenation)
$secretName = $Name
Write-Info "Secret name in vault: $secretName"

# Fetch existing secret to verify it exists and get current env-var-name
Write-Step "Fetching existing secret..."

try {
    $existingSecret = az keyvault secret show `
        --vault-name $settings.vaultName `
        --name $secretName 2>$null | ConvertFrom-Json
    
    if (-not $existingSecret) {
        throw "Secret not found"
    }
    
    Write-Success "Found existing secret: $secretName"
} catch {
    Write-Stderr "`n[ERROR] Secret '$secretName' not found in vault '$($settings.vaultName)'."
    Write-Stderr "   Use 'wr-save' to create a new secret."
    exit 1
}

# Get the existing env-var-name tag if EnvVarName not provided
$existingEnvVarName = $existingSecret.tags.'env-var-name'

if ([string]::IsNullOrWhiteSpace($EnvVarName)) {
    if ([string]::IsNullOrWhiteSpace($existingEnvVarName)) {
        Write-Stderr "`n[ERROR] No existing env-var-name tag found and -EnvVarName not provided."
        Write-Stderr "   Please provide -EnvVarName parameter."
        exit 1
    }
    $EnvVarName = $existingEnvVarName
    Write-Info "Using existing env variable: $EnvVarName"
} else {
    if ($existingEnvVarName -and $EnvVarName -ne $existingEnvVarName) {
        Write-Info "Changing env variable: $existingEnvVarName -> $EnvVarName"
    } else {
        Write-Info "Environment variable: $EnvVarName"
    }
}

# Get the secret value
if ([string]::IsNullOrWhiteSpace($Value)) {
    Write-Stderr ""
    $Value = Read-SecureValue -Prompt "Enter new value for '$secretName': "
    
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Stderr "`n[ERROR] No value provided. Aborting."
        exit 1
    }
}

# Update the secret in KeyVault with resource and env-var-name tags
Write-Step "Updating secret in KeyVault '$($settings.vaultName)'..."

try {
    az keyvault secret set `
        --vault-name $settings.vaultName `
        --name $secretName `
        --value $Value `
        --tags "resource=$Resource" "env-var-name=$EnvVarName" | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update secret in KeyVault"
    }
    
    Write-Success "Secret updated in KeyVault"
} catch {
    Write-Stderr "`n[ERROR] Failed to update secret: $_"
    Write-Stderr "   Make sure you have permissions to update secrets."
    exit 1
}

# Set environment variable in current session or output export command
if ($Export) {
    # Output shell-compatible export command
    Write-Stderr "`n[SUCCESS] Secret updated and exported to current session"
    Write-Stderr "  Resource:      $Resource"
    Write-Stderr "  Secret name:   $secretName"
    Write-Stderr "  Env variable:  $EnvVarName"
    
    # Escape special characters in value
    $escapedValue = $Value -replace "'", "'\''"
    
    switch ($Export) {
        "fish" {
            Write-Output "set -gx $EnvVarName '$escapedValue';"
        }
        "bash" {
            Write-Output "export $EnvVarName='$escapedValue';"
        }
        "zsh" {
            Write-Output "export $EnvVarName='$escapedValue';"
        }
        "powershell" {
            Write-Output "`$env:$EnvVarName = '$escapedValue';"
        }
    }
} else {
    # Set in current PowerShell session
    [Environment]::SetEnvironmentVariable($EnvVarName, $Value, "Process")
    
    # Summary
    Write-Host "`n+==============================================================+" -ForegroundColor Green
    Write-Host "|                    Secret Updated!                           |" -ForegroundColor Green
    Write-Host "+==============================================================+" -ForegroundColor Green

    Write-Host "`nDetails:" -ForegroundColor Yellow
    Write-Host "  Resource:      $Resource" -ForegroundColor White
    Write-Host "  Secret name:   $secretName" -ForegroundColor White
    Write-Host "  Env variable:  $EnvVarName" -ForegroundColor White
    Write-Host "  Session:       Updated in current shell" -ForegroundColor White
    Write-Host ""
}
