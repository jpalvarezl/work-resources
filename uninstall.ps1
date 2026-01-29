#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Uninstall work-resources CLI tools.

.DESCRIPTION
    Removes work-resources configuration from all shell profiles.
    This is a convenience wrapper for: ./install.ps1 -Uninstall

.EXAMPLE
    ./uninstall.ps1
    Removes CLI configuration from all shell profiles.
#>

$ScriptRoot = $PSScriptRoot
& "$ScriptRoot/install.ps1" -Uninstall
