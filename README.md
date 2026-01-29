# Azure KeyVault Secrets Manager

A cross-platform PowerShell Core project to securely manage test environment variables using Azure KeyVault. Organize secrets by resource (e.g., `resourceA`, `resourceB`) and load them as environment variables on demand.

## Features

- ✅ **Auto-provisioning**: Creates KeyVault and resource group if they don't exist
- ✅ **Cross-platform**: Works on Windows, macOS, and WSL/Linux
- ✅ **Resource-based organization**: Group secrets by resource (API, database, etc.)
- ✅ **Accumulate mode**: Load multiple resources without clearing previous ones
- ✅ **Secure input**: Masked prompts for secret values (never in shell history)
- ✅ **Local tracking**: `resources.json` maps secrets to environment variable names
- ✅ **Global CLI**: Install `wr-*` commands for use from any directory

## Installation

### Prerequisites

1. **PowerShell Core (pwsh)**

   | Platform | Install Command |
   |----------|----------------|
   | **Windows** | `winget install Microsoft.PowerShell` (or pre-installed) |
   | **macOS** | `brew install powershell` |
   | **Ubuntu/Debian** | `sudo apt-get install -y powershell` |
   | **Other Linux** | See [Microsoft docs](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux) |

2. **Azure CLI**

   | Platform | Install Command |
   |----------|----------------|
   | **Windows** | `winget install Microsoft.AzureCLI` |
   | **macOS** | `brew install azure-cli` |
   | **Linux** | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |

3. **Azure Account** - [Create a free account](https://azure.microsoft.com/free/) if you don't have one.

### Global CLI Installation

Install the `wr-*` commands to use from any directory:

**macOS / Linux / WSL:**
```bash
./install.sh
```

**Windows (PowerShell):**
```powershell
./install.ps1
```

This configures your shell profiles (PowerShell, bash, zsh, fish) with:
- `WORK_RESOURCES_ROOT` environment variable
- `wr-*` command aliases/PATH

**Restart your shell** after installation, or source your profile manually.

### Uninstall

```powershell
./uninstall.ps1
# or
./install.ps1 -Uninstall
```

## Quick Start

### 1. Configure Your Vault

Copy the environment template and fill in your values:

```bash
cp .env.template .env
```

Edit `.env` with your desired vault name:

```bash
# Azure KeyVault Configuration
VAULT_NAME=my-test-secrets-vault
RESOURCE_GROUP_NAME=test-secrets-rg
SUBSCRIPTION_ID=your-subscription-id  # Optional, uses default if empty
```

- `VAULT_NAME`: Globally unique name (3-24 chars, alphanumeric and hyphens)
- `RESOURCE_GROUP_NAME`: Resource group to create/use
- `SUBSCRIPTION_ID`: Leave empty for default subscription

> **Note:** The `.env` file is gitignored and should never be committed.

### 2. Run Setup

```powershell
wr-setup
# or: ./scripts/setup.ps1
```

This will:
- Verify Azure CLI is installed
- Log you into Azure (opens browser)
- Create the resource group if missing
- Create the KeyVault if missing
- Assign yourself the "Key Vault Secrets Officer" role

### 3. Add Secrets

```powershell
# Interactive (recommended - value is masked)
wr-save -Resource myapi -Name api-key

# With value inline (less secure - appears in history)
wr-save -Resource myapi -Name endpoint -Value "https://api.example.com"

# Custom environment variable name
wr-save -Resource myapi -Name key -EnvVarName "MY_CUSTOM_API_KEY"
```

### 4. Load Secrets

After installation, `wr-load` works the same way in all shells:

```bash
# Load secrets for a single resource
wr-load -Resource myapi

# Load multiple resources
wr-load -Resource "myapi,database"

# Load all resources
wr-load -Resource all
```

> **Note:** When loading multiple resources, if any share the same environment variable names, later values will overwrite earlier ones.

### 5. Use in Your Tests

```powershell
# After loading, secrets are available as env vars
echo $env:MYAPI_API_KEY
echo $env:MYAPI_ENDPOINT

# Run your tests
npm test
pytest
dotnet test
```

### 6. Clear When Done

```powershell
# Clear all loaded secrets
wr-clear

# Clear specific resource
wr-clear -Resource myapi
```

## CLI Commands Reference

After installation, these commands are available from any directory:

| Command | Description |
|---------|-------------|
| `wr-setup` | Initial KeyVault setup |
| `wr-save` | Save a secret to KeyVault |
| `wr-load` | Load secrets into environment |
| `wr-list` | List configured secrets |
| `wr-delete` | Delete a secret from KeyVault |
| `wr-clear` | Clear secrets from environment |

### `wr-setup`

First-time setup and vault creation.

```powershell
wr-setup          # Initial setup
wr-setup -Force   # Re-apply permissions
```

### `wr-save`

Add or update a secret in KeyVault.

```powershell
wr-save -Resource <name> -Name <secret-name> [-Value <value>] [-EnvVarName <custom-var>]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource group (e.g., "myapi", "database"). Must start with a letter and contain only letters, numbers, and hyphens (no underscores). |
| `-Name` | Yes | Secret name (e.g., "api-key", "connection-string"). Same naming rules as Resource. |
| `-Value` | No | Secret value (prompts if not provided) |
| `-EnvVarName` | No | Custom env var name (auto-generated if not provided) |

**Naming convention**: `{resource}-{name}` → `{RESOURCE}_{NAME}`
- `myapi` + `api-key` → KeyVault: `myapi-api-key` → Env: `MYAPI_API_KEY`

### `wr-load`

Load secrets into current session as environment variables.

```powershell
wr-load -Resource <name|all> [-Export <shell>] [-SpawnShell]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource name(s) or "all" |
| `-Export` | No | Output format: `bash`, `zsh`, `fish`, `powershell` |
| `-SpawnShell` | No | Spawn new shell with secrets (isolated) |

**Examples**:
```powershell
wr-load -Resource myapi                    # Single resource
wr-load -Resource "myapi,shared"           # Multiple (comma-separated)
wr-load -Resource all                      # All resources
wr-load -Resource myapi -SpawnShell        # Isolated shell
```

### `wr-list`

Display configured resources and secrets.

```powershell
wr-list                     # List from config
wr-list -Verify             # Verify against KeyVault
wr-list -Resource myapi     # Filter by resource
```

### `wr-clear`

Remove loaded secrets from current session.

```powershell
wr-clear                    # Clear all (prompts)
wr-clear -Resource myapi    # Clear specific resource
wr-clear -Force             # Skip confirmation
```

### `wr-delete`

Delete secrets from KeyVault and local configuration.

```powershell
wr-delete -Resource <name> -Name <secret-name> [-Force]
wr-delete -Resource <name> -All [-Force]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource group name |
| `-Name` | No* | Secret name to delete (*required unless -All is used) |
| `-All` | No | Delete all secrets for the resource |
| `-Force` | No | Skip confirmation prompt |

**Examples**:
```powershell
wr-delete -Resource myapi -Name api-key    # Delete single secret
wr-delete -Resource myapi -All             # Delete entire resource
wr-delete -Resource myapi -All -Force      # No confirmation
```

## Project Structure

```
work-resources/
├── README.md                 # This file
├── .env.template             # Configuration template (copy to .env)
├── .env                      # Your local configuration (gitignored)
├── install.ps1               # CLI installer (cross-platform)
├── install.sh                # CLI installer wrapper (macOS/Linux)
├── uninstall.ps1             # CLI uninstaller
├── bin/                      # Shell wrappers for wr-* commands
│   ├── wr-load, wr-save, ... # Bash wrappers
│   └── wr-load.cmd, ...      # Windows wrappers
├── config/
│   └── resources.json        # Secret → env var mappings (auto-managed)
└── scripts/
    ├── common.ps1            # Shared helper functions
    ├── setup.ps1             # Initial setup & vault creation
    ├── load-env.ps1          # Load secrets as env vars
    ├── save-secret.ps1       # Add/update secrets
    ├── list-secrets.ps1      # Show configured secrets
    └── clear-env.ps1         # Clear loaded env vars
```

## Typical Workflow

```bash
# One-time setup
wr-setup

# Add secrets for your API resource
wr-save -Resource myapi -Name api-key
wr-save -Resource myapi -Name api-secret
wr-save -Resource myapi -Name endpoint

# Add secrets for database
wr-save -Resource database -Name connection-string
wr-save -Resource database -Name password

# View what's configured
wr-list

# When running tests
wr-load -Resource "myapi,database"
npm test  # or your test command

# Clean up
wr-clear
```

## Security Notes

- **Never commit secrets**: Only secret *names* are stored in `resources.json`, not values
- **Use interactive input**: Prefer prompted input over `-Value` parameter to keep secrets out of shell history
- **Session isolation**: Consider `-SpawnShell` for extra isolation; exit returns to clean session
- **RBAC permissions**: The setup script uses "Key Vault Secrets Officer" role (least privilege for this use case)

## Troubleshooting

### "Vault not found" error
Run `wr-setup` to create the vault.

### "Access denied" error
Run `wr-setup -Force` to re-apply permissions.

### "az: command not found"
Install Azure CLI for your platform (see Prerequisites).

### Secrets not loading
1. Check `wr-list -Verify` to see if secrets exist in vault
2. Ensure you're logged in: `az account show`
3. Verify vault name in `.env`

## License

MIT
