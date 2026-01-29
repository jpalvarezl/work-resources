#!/usr/bin/env bash
#
# install.sh - Install work-resources CLI tools
#
# This script checks for PowerShell Core and then runs install.ps1
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${CYAN}[INSTALL] work-resources CLI tools${NC}"
echo ""

# Check if pwsh is installed
if ! command -v pwsh &> /dev/null; then
    echo -e "${RED}[ERROR] PowerShell Core (pwsh) is not installed.${NC}"
    echo ""
    echo "PowerShell Core is required to run work-resources scripts."
    echo "Please install it first:"
    echo ""
    
    # Detect OS and provide appropriate instructions
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e "${YELLOW}macOS:${NC}"
        echo "  brew install powershell"
        echo ""
        echo "  Or visit: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos"
    elif [[ -f /etc/debian_version ]]; then
        echo -e "${YELLOW}Debian/Ubuntu:${NC}"
        echo "  # Install prerequisites"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install -y wget apt-transport-https software-properties-common"
        echo ""
        echo "  # Download and install Microsoft repository"
        echo "  wget -q https://packages.microsoft.com/config/ubuntu/\$(lsb_release -rs)/packages-microsoft-prod.deb"
        echo "  sudo dpkg -i packages-microsoft-prod.deb"
        echo "  rm packages-microsoft-prod.deb"
        echo ""
        echo "  # Install PowerShell"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install -y powershell"
    elif [[ -f /etc/redhat-release ]]; then
        echo -e "${YELLOW}RHEL/CentOS/Fedora:${NC}"
        echo "  sudo dnf install -y powershell"
        echo ""
        echo "  Or visit: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
    else
        echo -e "${YELLOW}Linux:${NC}"
        echo "  Visit: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
    fi
    
    echo ""
    echo "After installing PowerShell, run this script again."
    exit 1
fi

echo -e "${GREEN}[OK] PowerShell Core found: $(pwsh --version)${NC}"
echo ""

# Run the PowerShell installer
exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/install.ps1" "$@"
