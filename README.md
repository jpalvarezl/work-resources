# Azure KeyVault Secrets Manager

A cross-platform PowerShell Core project to securely manage test environment variables using Azure KeyVault. Organize secrets by resource (e.g., `resourceA`, `resourceB`) and load them as environment variables on demand.

## Features

- ✅ **Auto-provisioning**: Creates KeyVault and resource group if they don't exist
- ✅ **Cross-platform**: Works on Windows, macOS, and WSL/Linux
- ✅ **Resource-based organization**: Group secrets by resource (API, database, etc.)
- ✅ **Accumulate mode**: Load multiple resources without clearing previous ones
- ✅ **Secure input**: Masked prompts for secret values (never in shell history)
- ✅ **Local tracking**: `resources.json` maps secrets to environment variable names

## Prerequisites

### 1. PowerShell Core (pwsh)

| Platform | Install Command |
|----------|----------------|
| **Windows** | `winget install Microsoft.PowerShell` (or pre-installed) |
| **macOS** | `brew install powershell` |
| **Ubuntu/Debian** | `sudo apt-get install -y powershell` |
| **Other Linux** | See [Microsoft docs](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux) |

Verify installation:
```bash
pwsh --version
```

### 2. Azure CLI

| Platform | Install Command |
|----------|----------------|
| **Windows** | `winget install Microsoft.AzureCLI` |
| **macOS** | `brew install azure-cli` |
| **Linux** | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |

Verify installation:
```bash
az --version
```

### 3. Azure Account

You need an Azure subscription. [Create a free account](https://azure.microsoft.com/free/) if you don't have one.

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
./scripts/setup.ps1
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
./scripts/save-secret.ps1 -Resource myapi -Name api-key

# With value inline (less secure - appears in history)
./scripts/save-secret.ps1 -Resource myapi -Name endpoint -Value "https://api.example.com"
```

### 4. Load Secrets

**For fish shell:**
```fish
eval (pwsh ./scripts/load-env.ps1 -Resource myapi -Export fish)
```

**For bash/zsh:**
```bash
eval "$(pwsh ./scripts/load-env.ps1 -Resource myapi -Export bash)"
```

**For PowerShell:**
```powershell
./scripts/load-env.ps1 -Resource myapi
```

**Load multiple resources:**
```fish
# fish
eval (pwsh ./scripts/load-env.ps1 -Resource "myapi,database" -Export fish)

# bash/zsh
eval "$(pwsh ./scripts/load-env.ps1 -Resource all -Export bash)"
```

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
./scripts/clear-env.ps1

# Clear specific resource
./scripts/clear-env.ps1 -Resource myapi
```

## Usage Reference

### `setup.ps1`

First-time setup and vault creation.

```powershell
./scripts/setup.ps1          # Initial setup
./scripts/setup.ps1 -Force   # Re-apply permissions
```

### `save-secret.ps1`

Add or update a secret in KeyVault.

```powershell
./scripts/save-secret.ps1 -Resource <name> -Name <secret-name> [-Value <value>] [-EnvVarName <custom-var>]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource group (e.g., "myapi", "database"). Must start with a letter and contain only letters, numbers, and hyphens (no underscores). |
| `-Name` | Yes | Secret name (e.g., "api-key", "connection-string"). Same naming rules as Resource. |
| `-Value` | No | Secret value (prompts if not provided) |
| `-EnvVarName` | No | Custom env var name (auto-generated if not provided) |

**Naming convention**: `{resource}-{name}` → `{RESOURCE}_{NAME}`
- `myapi` + `api-key` → KeyVault: `myapi-api-key` → Env: `MYAPI_API_KEY`

### `load-env.ps1`

Load secrets into current session as environment variables.

```powershell
./scripts/load-env.ps1 -Resource <name|all> [-SpawnShell]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource name(s) or "all" |
| `-SpawnShell` | No | Spawn new shell with secrets (isolated) |

**Examples**:
```powershell
./scripts/load-env.ps1 -Resource myapi           # Single resource
./scripts/load-env.ps1 -Resource "myapi,shared"  # Multiple (comma-separated)
./scripts/load-env.ps1 -Resource all             # All resources
./scripts/load-env.ps1 -Resource myapi -SpawnShell  # Isolated shell
```

### `list-secrets.ps1`

Display configured resources and secrets.

```powershell
./scripts/list-secrets.ps1              # List from config
./scripts/list-secrets.ps1 -Verify      # Verify against KeyVault
./scripts/list-secrets.ps1 -Resource myapi  # Filter by resource
```

### `clear-env.ps1`

Remove loaded secrets from current session.

```powershell
./scripts/clear-env.ps1                    # Clear all (prompts)
./scripts/clear-env.ps1 -Resource myapi    # Clear specific resource
./scripts/clear-env.ps1 -Force             # Skip confirmation
```

## Project Structure

```
work_resources/
├── README.md                 # This file
├── .gitignore
├── .env.template             # Configuration template (copy to .env)
├── .env                      # Your local configuration (gitignored)
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

```powershell
# One-time setup
./scripts/setup.ps1

# Add secrets for your API resource
./scripts/save-secret.ps1 -Resource myapi -Name api-key
./scripts/save-secret.ps1 -Resource myapi -Name api-secret
./scripts/save-secret.ps1 -Resource myapi -Name endpoint

# Add secrets for database
./scripts/save-secret.ps1 -Resource database -Name connection-string
./scripts/save-secret.ps1 -Resource database -Name password

# View what's configured
./scripts/list-secrets.ps1

# When running tests
./scripts/load-env.ps1 -Resource "myapi,database"
npm test  # or your test command

# Clean up
./scripts/clear-env.ps1
```

## Security Notes

- **Never commit secrets**: Only secret *names* are stored in `resources.json`, not values
- **Use interactive input**: Prefer prompted input over `-Value` parameter to keep secrets out of shell history
- **Session isolation**: Consider `-SpawnShell` for extra isolation; exit returns to clean session
- **RBAC permissions**: The setup script uses "Key Vault Secrets Officer" role (least privilege for this use case)

## Troubleshooting

### "Vault not found" error
Run `./scripts/setup.ps1` to create the vault.

### "Access denied" error
Run `./scripts/setup.ps1 -Force` to re-apply permissions.

### "az: command not found"
Install Azure CLI for your platform (see Prerequisites).

### Secrets not loading
1. Check `./scripts/list-secrets.ps1 -Verify` to see if secrets exist in vault
2. Ensure you're logged in: `az account show`
3. Verify vault name in `.env`

## License

MIT
