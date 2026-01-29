#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install work-resources CLI tools globally.

.DESCRIPTION
    Copies scripts to a user-local directory and configures shell profiles
    to make wr-* commands available from anywhere.
    
    Install locations:
    - Linux/macOS: ~/.local/share/work-resources/
    - Windows: $HOME\.work-resources\

.PARAMETER Uninstall
    Remove work-resources installation and configuration.

.EXAMPLE
    ./install.ps1
    Installs CLI tools for all detected shells.

.EXAMPLE
    ./install.ps1 -Uninstall
    Removes installation and configuration.
#>

param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# Markers for identifying our config blocks
$MarkerStart = "# >>> work-resources >>>"
$MarkerEnd = "# <<< work-resources <<<"

# Source directory (where install.ps1 is located)
$SourceRoot = $PSScriptRoot

# Determine install location based on OS
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $InstallRoot = Join-Path $HOME ".work-resources"
    $IsWindowsOS = $true
} else {
    $InstallRoot = Join-Path $HOME ".local/share/work-resources"
    $LocalBin = Join-Path $HOME ".local/bin"
    $IsWindowsOS = $false
}

$ScriptsDir = Join-Path $InstallRoot "scripts"
$ConfigDir = Join-Path $InstallRoot "config"
$BinDir = Join-Path $InstallRoot "bin"

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

function Write-Err {
    param([string]$Message)
    Write-Host "  [X] $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-ShellProfilePath {
    param([string]$Shell)
    
    switch ($Shell) {
        "pwsh" {
            # PowerShell Core 7.x - use the actual profile path from the running pwsh
            return $PROFILE.CurrentUserAllHosts
        }
        "bash" {
            $bashrc = Join-Path $HOME ".bashrc"
            if (Test-Path $bashrc) { return $bashrc }
            return Join-Path $HOME ".bash_profile"
        }
        "zsh" {
            return Join-Path $HOME ".zshrc"
        }
        "fish" {
            return Join-Path $HOME ".config/fish/config.fish"
        }
    }
}

function Test-AlreadyInstalled {
    param([string]$ProfilePath)
    
    if (-not (Test-Path $ProfilePath)) {
        return $false
    }
    
    $content = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
    return $content -match [regex]::Escape($MarkerStart)
}

function Remove-ConfigBlock {
    param([string]$ProfilePath)
    
    if (-not (Test-Path $ProfilePath)) {
        return $false
    }
    
    $content = Get-Content $ProfilePath -Raw
    $pattern = "(?s)$([regex]::Escape($MarkerStart)).*?$([regex]::Escape($MarkerEnd))\r?\n?"
    
    if ($content -match $pattern) {
        $newContent = $content -replace $pattern, ""
        $newContent = $newContent -replace "(\r?\n){3,}", "`n`n"
        Set-Content $ProfilePath -Value $newContent.TrimEnd() -NoNewline
        Add-Content $ProfilePath -Value ""
        return $true
    }
    return $false
}

function Add-ConfigBlock {
    param(
        [string]$ProfilePath,
        [string]$ConfigContent
    )
    
    $parentDir = Split-Path $ProfilePath -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }
    
    $existingContent = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
    $prefix = ""
    if ($existingContent -and $existingContent.TrimEnd().Length -gt 0) {
        $prefix = "`n"
    }
    
    Add-Content $ProfilePath -Value "$prefix$ConfigContent"
}

# -----------------------------------------------------------------------------
# Installation Functions
# -----------------------------------------------------------------------------

function Install-Files {
    Write-Step "Installing files to $InstallRoot"
    
    # Create directories
    foreach ($dir in @($InstallRoot, $ScriptsDir, $ConfigDir, $BinDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    
    # Copy scripts
    $scriptFiles = Get-ChildItem (Join-Path $SourceRoot "scripts") -Filter "*.ps1"
    foreach ($file in $scriptFiles) {
        Copy-Item $file.FullName $ScriptsDir -Force
    }
    Write-Success "Copied $($scriptFiles.Count) PowerShell scripts"
    
    # Copy bin wrappers (for bash)
    $binFiles = Get-ChildItem (Join-Path $SourceRoot "bin") -File | Where-Object { $_.Extension -eq "" -or $_.Extension -eq ".cmd" }
    foreach ($file in $binFiles) {
        Copy-Item $file.FullName $BinDir -Force
    }
    Write-Success "Copied $($binFiles.Count) shell wrappers"
    
    # On Linux/macOS, set execute permissions on bash wrappers
    if (-not $IsWindowsOS) {
        $bashWrappers = Get-ChildItem $BinDir -File | Where-Object { $_.Extension -eq "" }
        foreach ($wrapper in $bashWrappers) {
            chmod +x $wrapper.FullName
        }
    }
    
    # Handle resources.json - migrate from source if exists and destination is empty/missing
    $destResourcesJson = Join-Path $ConfigDir "resources.json"
    $sourceResourcesJson = Join-Path $SourceRoot "config/resources.json"
    
    if (-not (Test-Path $destResourcesJson)) {
        # Destination doesn't exist - check if source has one to migrate
        if ((Test-Path $sourceResourcesJson)) {
            $sourceContent = Get-Content $sourceResourcesJson -Raw | ConvertFrom-Json
            if ($sourceContent.resources.PSObject.Properties.Count -gt 0) {
                Copy-Item $sourceResourcesJson $destResourcesJson -Force
                Write-Success "Migrated resources.json from source ($($sourceContent.resources.PSObject.Properties.Count) resource(s))"
            } else {
                # Source is empty, create fresh
                $initialConfig = @{ resources = @{} } | ConvertTo-Json -Depth 10
                Set-Content $destResourcesJson -Value $initialConfig -Encoding UTF8
                Write-Success "Created empty resources.json"
            }
        } else {
            # No source, create fresh
            $initialConfig = @{ resources = @{} } | ConvertTo-Json -Depth 10
            Set-Content $destResourcesJson -Value $initialConfig -Encoding UTF8
            Write-Success "Created empty resources.json"
        }
    } else {
        Write-Info "Kept existing resources.json"
    }
    
    # Copy .env.template
    $envTemplate = Join-Path $SourceRoot ".env.template"
    if (Test-Path $envTemplate) {
        Copy-Item $envTemplate (Join-Path $ConfigDir ".env.template") -Force
    }
    
    # Handle .env - migrate from source if exists, otherwise exit with error
    $destEnvFile = Join-Path $ConfigDir ".env"
    $sourceEnvFile = Join-Path $SourceRoot ".env"
    
    if (-not (Test-Path $destEnvFile)) {
        # Destination doesn't exist - check if source has one to migrate
        if ((Test-Path $sourceEnvFile)) {
            Copy-Item $sourceEnvFile $destEnvFile -Force
            Write-Success "Migrated .env from source"
        } else {
            # No .env file - cannot continue
            Write-Host ""
            Write-Host "[ERROR] .env file not found!" -ForegroundColor Red
            Write-Host ""
            Write-Host "  You must create a .env file before installation can complete." -ForegroundColor Yellow
            Write-Host "  Template location: $ConfigDir/.env.template" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Required values:" -ForegroundColor Cyan
            Write-Host "    VAULT_NAME=your-keyvault-name"
            Write-Host "    RESOURCE_GROUP_NAME=your-resource-group"
            Write-Host "    SUBSCRIPTION_ID=your-subscription-id (optional)"
            Write-Host ""
            Write-Host "  Create the file at: $destEnvFile" -ForegroundColor Cyan
            Write-Host "  Then re-run this installer." -ForegroundColor Cyan
            Write-Host ""
            exit 1
        }
    } else {
        Write-Info "Kept existing .env"
    }
}

function Uninstall-Files {
    Write-Step "Removing installed files"
    
    if (Test-Path $InstallRoot) {
        Remove-Item $InstallRoot -Recurse -Force
        Write-Success "Removed $InstallRoot"
    } else {
        Write-Info "Install directory not found"
    }
    
    # On Linux/macOS, remove symlinks from ~/.local/bin
    if (-not $IsWindowsOS) {
        $commands = @("wr-load", "wr-save", "wr-delete", "wr-list", "wr-clear", "wr-setup")
        $removedAny = $false
        foreach ($cmd in $commands) {
            $linkPath = Join-Path $LocalBin $cmd
            if (Test-Path $linkPath) {
                Remove-Item $linkPath -Force
                $removedAny = $true
            }
        }
        if ($removedAny) {
            Write-Success "Removed symlinks from ~/.local/bin"
        }
    }
}

# -----------------------------------------------------------------------------
# Shell-specific config generators
# -----------------------------------------------------------------------------

function Get-PowerShellConfig {
    return @"
$MarkerStart
# Azure KeyVault Secrets Manager
`$env:WORK_RESOURCES_ROOT = "$InstallRoot"

function wr-load { & "`$env:WORK_RESOURCES_ROOT/scripts/load-env.ps1" @args }
function wr-save { & "`$env:WORK_RESOURCES_ROOT/scripts/save-secret.ps1" @args }
function wr-delete { & "`$env:WORK_RESOURCES_ROOT/scripts/delete-secret.ps1" @args }
function wr-list { & "`$env:WORK_RESOURCES_ROOT/scripts/list-secrets.ps1" @args }
function wr-clear { & "`$env:WORK_RESOURCES_ROOT/scripts/clear-env.ps1" @args }
function wr-setup { & "`$env:WORK_RESOURCES_ROOT/scripts/setup.ps1" @args }
$MarkerEnd
"@
}

function Get-BashConfig {
    $localBin = Join-Path $HOME ".local/bin"
    
    return @"
$MarkerStart
# Azure KeyVault Secrets Manager
export WORK_RESOURCES_ROOT="$InstallRoot"
export PATH="$localBin`:`$PATH"

# wr-load must be a function to set env vars in current shell
wr-load() {
    eval "`$(pwsh -NoProfile -ExecutionPolicy Bypass -File "`$WORK_RESOURCES_ROOT/scripts/load-env.ps1" -Export bash "`$@")"
}

# wr-clear must be a function to unset env vars in current shell
wr-clear() {
    eval "`$(pwsh -NoProfile -ExecutionPolicy Bypass -File "`$WORK_RESOURCES_ROOT/scripts/clear-env.ps1" -Export bash "`$@")"
}
$MarkerEnd
"@
}

function Get-ZshConfig {
    return Get-BashConfig
}

function Get-FishConfig {
    $localBin = Join-Path $HOME ".local/bin"
    
    return @"
$MarkerStart
# Azure KeyVault Secrets Manager
set -gx WORK_RESOURCES_ROOT "$InstallRoot"
fish_add_path "$localBin"

# wr-load must be a function to set env vars in current shell
function wr-load
    eval (pwsh -NoProfile -ExecutionPolicy Bypass -File "`$WORK_RESOURCES_ROOT/scripts/load-env.ps1" -Export fish `$argv)
end

# wr-clear must be a function to unset env vars in current shell
function wr-clear
    eval (pwsh -NoProfile -ExecutionPolicy Bypass -File "`$WORK_RESOURCES_ROOT/scripts/clear-env.ps1" -Export fish `$argv)
end
$MarkerEnd
"@
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

if ($Uninstall) {
    Write-Host "`n[UNINSTALL] Removing work-resources CLI" -ForegroundColor Magenta
} else {
    Write-Host "`n[INSTALL] Installing work-resources CLI" -ForegroundColor Magenta
    Write-Info "Source: $SourceRoot"
    Write-Info "Destination: $InstallRoot"
}

# Handle file installation/removal
if ($Uninstall) {
    Uninstall-Files
} else {
    Install-Files
    
    # On native Linux/macOS, create symlinks in ~/.local/bin for bash wrappers
    if (-not $IsWindowsOS) {
        Write-Step "Creating symlinks in ~/.local/bin"
        if (-not (Test-Path $LocalBin)) {
            New-Item -ItemType Directory -Path $LocalBin -Force | Out-Null
        }
        $commands = @("wr-load", "wr-save", "wr-delete", "wr-list", "wr-clear", "wr-setup")
        foreach ($cmd in $commands) {
            $linkPath = Join-Path $LocalBin $cmd
            $targetPath = Join-Path $BinDir $cmd
            if (Test-Path $linkPath) { Remove-Item $linkPath -Force }
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath -Force | Out-Null
        }
        Write-Success "Created symlinks"
    }
}

# Detect available shells
$shells = @()

# PowerShell Core 7.x (pwsh) - required, installer runs in pwsh
$shells += @{ Name = "pwsh"; Display = "PowerShell Core (pwsh)"; Available = $true }

# Bash/Zsh/Fish only available on Linux/macOS (not on Windows)
if (-not $IsWindowsOS) {
    if (Test-CommandExists "bash") {
        $shells += @{ Name = "bash"; Display = "Bash"; Available = $true }
    } else {
        $shells += @{ Name = "bash"; Display = "Bash"; Available = $false }
    }
    
    if (Test-CommandExists "zsh") {
        $shells += @{ Name = "zsh"; Display = "Zsh"; Available = $true }
    } else {
        $shells += @{ Name = "zsh"; Display = "Zsh"; Available = $false }
    }
    
    if (Test-CommandExists "fish") {
        $shells += @{ Name = "fish"; Display = "Fish"; Available = $true }
    } else {
        $shells += @{ Name = "fish"; Display = "Fish"; Available = $false }
    }
}

Write-Step "Detected shells:"
foreach ($shell in $shells) {
    if ($shell.Available) {
        Write-Success "$($shell.Display)"
    } else {
        Write-Info "$($shell.Display) (not installed)"
    }
}

# Process each available shell
$configured = @()
$skipped = @()
$failed = @()

foreach ($shell in $shells | Where-Object { $_.Available }) {
    $profilePath = Get-ShellProfilePath -Shell $shell.Name
    
    Write-Step "Configuring $($shell.Display)..."
    Write-Info "Profile: $profilePath"
    
    if ($Uninstall) {
        $removed = Remove-ConfigBlock -ProfilePath $profilePath
        if ($removed) {
            Write-Success "Removed configuration"
            $configured += $shell.Display
        } else {
            Write-Info "No configuration found"
            $skipped += $shell.Display
        }
    } else {
        if (Test-AlreadyInstalled -ProfilePath $profilePath) {
            # Remove old config first, then add new one (update)
            Remove-ConfigBlock -ProfilePath $profilePath | Out-Null
        }
        
        try {
            $config = switch ($shell.Name) {
                "pwsh" { Get-PowerShellConfig }
                "bash" { Get-BashConfig }
                "zsh" { Get-ZshConfig }
                "fish" { Get-FishConfig }
            }
            
            Add-ConfigBlock -ProfilePath $profilePath -ConfigContent $config
            Write-Success "Configuration added"
            $configured += $shell.Display
        } catch {
            Write-Err "Failed: $_"
            $failed += $shell.Display
        }
    }
}

# Summary
Write-Host "`n" -NoNewline
if ($Uninstall) {
    Write-Host "+==============================================================+" -ForegroundColor Green
    Write-Host "|                 Uninstallation Complete                      |" -ForegroundColor Green
    Write-Host "+==============================================================+`n" -ForegroundColor Green
} else {
    Write-Host "+==============================================================+" -ForegroundColor Green
    Write-Host "|                 Installation Complete                        |" -ForegroundColor Green
    Write-Host "+==============================================================+`n" -ForegroundColor Green
}

if ($configured.Count -gt 0) {
    $action = if ($Uninstall) { "Removed from" } else { "Configured" }
    Write-Host "  $action`: $($configured -join ', ')"
}
if ($skipped.Count -gt 0) {
    Write-Host "  Skipped: $($skipped -join ', ')"
}
if ($failed.Count -gt 0) {
    Write-Host "  Failed: $($failed -join ', ')" -ForegroundColor Red
}

if (-not $Uninstall) {
    Write-Host "`nInstall location: $InstallRoot" -ForegroundColor Cyan
    
    Write-Host "`nAvailable commands:" -ForegroundColor Cyan
    Write-Host "  wr-load     Load secrets into environment"
    Write-Host "  wr-save     Save a secret to KeyVault"
    Write-Host "  wr-delete   Delete a secret from KeyVault"
    Write-Host "  wr-list     List configured secrets"
    Write-Host "  wr-clear    Clear secrets from environment"
    Write-Host "  wr-setup    Initial KeyVault setup"
    
    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  1. Restart your shell (or source your profile)"
    Write-Host "  2. Create your .env file (see .env.template): $ConfigDir/.env"
    Write-Host "  3. Run: wr-setup"
}

Write-Host ""
