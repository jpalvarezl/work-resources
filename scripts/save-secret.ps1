#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Save a secret to Azure KeyVault.

.DESCRIPTION
    Adds or updates a secret in KeyVault with the naming convention:
    {resource}-{name}. The environment variable name is stored as a tag
    on the secret in KeyVault (env-var-name tag).

.PARAMETER Resource
    The resource group name (e.g., "myapp", "database", "shared").
    Must start with a letter and contain only letters, numbers, and hyphens.
    Underscores are not allowed due to Azure KeyVault naming restrictions.

.PARAMETER Name
    The secret name within the resource (e.g., "api-key", "connection-string").
    Must start with a letter and contain only letters, numbers, and hyphens.

.PARAMETER Value
    Optional: The secret value. If not provided, prompts interactively (recommended).

.PARAMETER EnvVarName
    Required: The environment variable name to use when loading this secret.
    Must start with a letter or underscore and contain only letters, numbers, 
    and underscores (e.g., "OPENAI_API_KEY", "DATABASE_URL").

.EXAMPLE
    ./save-secret.ps1 -Resource myapp -Name api-key -EnvVarName "MYAPP_API_KEY"
    Prompts for the value interactively (secure, not in shell history).

.EXAMPLE
    ./save-secret.ps1 -Resource myapp -Name api-key -EnvVarName "MYAPP_API_KEY" -Value "secret123"
    Sets value directly (less secure, appears in shell history).

.EXAMPLE
    ./save-secret.ps1 -Resource shared -Name openai-key -EnvVarName "OPENAI_API_KEY"
    Multiple resources can use the same env var name if desired.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Resource,
    
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]*$')]
    [string]$Name,
    
    [string]$Value,
    
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
    [string]$EnvVarName
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
    
    Write-Host "$Prompt" -ForegroundColor Yellow -NoNewline
    
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
            Write-Host ""  # New line after hidden input
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

Write-Host "`n[KEY] Save Secret to KeyVault" -ForegroundColor Magenta

# Check Azure login
Write-Step "Verifying Azure authentication..."
$account = Test-AzureLogin
Write-Success "Logged in as: $($account.user.name)"

# Load configuration
$settings = Get-Settings

# Build the full secret name
$secretName = "$Resource-$Name"
Write-Info "Secret name in vault: $secretName"
Write-Info "Environment variable: $EnvVarName"

# Get the secret value
if ([string]::IsNullOrWhiteSpace($Value)) {
    Write-Host ""
    $Value = Read-SecureValue -Prompt "Enter value for '$secretName': "
    
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Host "`n[ERROR] No value provided. Aborting." -ForegroundColor Red
        exit 1
    }
}

# Save to KeyVault with resource and env-var-name tags
Write-Step "Saving secret to KeyVault '$($settings.vaultName)'..."

try {
    az keyvault secret set `
        --vault-name $settings.vaultName `
        --name $secretName `
        --value $Value `
        --tags "resource=$Resource" "env-var-name=$EnvVarName" | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to save secret to KeyVault"
    }
    
    Write-Success "Secret saved to KeyVault"
} catch {
    Write-Host "`n[ERROR] Failed to save secret: $_" -ForegroundColor Red
    Write-Host "   Make sure the vault exists and you have permissions." -ForegroundColor DarkGray
    Write-Host "   Run ./setup.ps1 to verify." -ForegroundColor DarkGray
    exit 1
}

# Summary
Write-Host "`n+==============================================================+" -ForegroundColor Green
Write-Host "|                    Secret Saved!                             |" -ForegroundColor Green
Write-Host "+==============================================================+" -ForegroundColor Green

Write-Host "`nDetails:" -ForegroundColor Yellow
Write-Host "  Resource:      $Resource" -ForegroundColor White
Write-Host "  Secret name:   $secretName" -ForegroundColor White
Write-Host "  Env variable:  $EnvVarName" -ForegroundColor White

Write-Host "`nTo load this secret:" -ForegroundColor Yellow
Write-Host "  wr-load -Resource $Resource" -ForegroundColor White
Write-Host ""
