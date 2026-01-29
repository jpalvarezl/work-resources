#!/usr/bin/env bash
#
# uninstall.sh - Uninstall work-resources CLI tools
#
# This script checks for PowerShell Core and then runs uninstall.ps1
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${CYAN}[UNINSTALL] work-resources CLI tools${NC}"
echo ""

# Check if pwsh is installed
if ! command -v pwsh &> /dev/null; then
    echo -e "${RED}[ERROR] PowerShell Core (pwsh) is not installed.${NC}"
    echo ""
    echo "PowerShell Core is required to run the uninstall script."
    echo "If you installed manually, you can remove:"
    echo "  - ~/.local/share/work-resources"
    echo "  - ~/.local/bin/wr-* symlinks"
    echo "  - work-resources section from your shell profile (~/.bashrc, etc.)"
    exit 1
fi

# Run the PowerShell uninstall script
echo -e "${GREEN}Running uninstall.ps1...${NC}"
echo ""
pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/uninstall.ps1" -Force "$@"
