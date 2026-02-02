# Azure KeyVault Secrets Manager

A cross-platform PowerShell Core project to securely manage test environment variables using Azure KeyVault. Organize secrets by resource (e.g., `resourceA`, `resourceB`) and load them as environment variables on demand.

## Features

- ✅ **Auto-provisioning**: Creates KeyVault and resource group if they don't exist
- ✅ **Cross-platform**: Works on Windows, macOS, and WSL/Linux
- ✅ **Resource-based organization**: Group secrets by resource prefix (API, database, etc.)
- ✅ **Tag-based mapping**: Environment variable names stored as tags in KeyVault
- ✅ **Secure input**: Masked prompts for secret values (never in shell history)
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
wr-save -Resource myapi -Name api-key -EnvVarName MYAPI_API_KEY

# With value inline (less secure - appears in history)
wr-save -Resource myapi -Name endpoint -EnvVarName MYAPI_ENDPOINT -Value "https://api.example.com"
```

> **Note:** The `-EnvVarName` parameter is required. This is the environment variable name that will be set when you load the secret.

### 4. Load Secrets

After installation, `wr-load` works the same way in all shells:

```bash
# Load all secrets from the vault
wr-load

# Load secrets for a specific resource prefix
wr-load -Resource myapi

# Load multiple resources
wr-load -Resource "myapi,database"
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
| `wr-list` | List secrets in KeyVault |
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
wr-save -Resource <name> -Name <secret-name> -EnvVarName <env-var> [-Value <value>]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource prefix (e.g., "myapi", "database"). Must start with a letter and contain only letters, numbers, and hyphens (no underscores). |
| `-Name` | Yes | Secret name (e.g., "api-key", "connection-string"). Same naming rules as Resource. |
| `-EnvVarName` | Yes | Environment variable name (e.g., "MYAPI_API_KEY"). Must start with a letter/underscore and contain only letters, numbers, and underscores. |
| `-Value` | No | Secret value (prompts if not provided) |

**Naming**: The secret is stored in KeyVault as `{resource}-{name}` with an `env-var-name` tag.
- Example: `wr-save -Resource myapi -Name api-key -EnvVarName MYAPI_API_KEY`
- KeyVault secret name: `myapi-api-key`
- Tag: `env-var-name=MYAPI_API_KEY`

### `wr-load`

Load secrets into current session as environment variables.

```powershell
wr-load [-Resource <name>] [-Export <shell>] [-SpawnShell]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | No | Resource prefix(es) to filter (loads all if omitted) |
| `-Export` | No | Output format: `bash`, `zsh`, `fish`, `powershell` |
| `-SpawnShell` | No | Spawn new shell with secrets (isolated) |

**Examples**:
```powershell
wr-load                                    # Load all secrets
wr-load -Resource myapi                    # Filter by prefix
wr-load -Resource "myapi,shared"           # Multiple prefixes
wr-load -Resource myapi -SpawnShell        # Isolated shell
```

### `wr-list`

Display secrets in KeyVault.

```powershell
wr-list                     # List all secrets from KeyVault
wr-list -Resource myapi     # Filter by resource prefix
```

### `wr-clear`

Remove loaded secrets from current session.

```powershell
wr-clear                    # Clear all (prompts)
wr-clear -Resource myapi    # Clear specific resource
wr-clear -Force             # Skip confirmation
```

### `wr-delete`

Delete secrets from KeyVault.

```powershell
wr-delete -Resource <name> -Name <secret-name> [-Force]
wr-delete -Resource <name> -All [-Force]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource prefix |
| `-Name` | No* | Secret name to delete (*required unless -All is used) |
| `-All` | No | Delete all secrets with the resource prefix |
| `-Force` | No | Skip confirmation prompt |

**Examples**:
```powershell
wr-delete -Resource myapi -Name api-key    # Delete single secret
wr-delete -Resource myapi -All             # Delete all myapi-* secrets
wr-delete -Resource myapi -All -Force      # No confirmation
```

## Project Structure

```
- `bin/` - Shell wrappers that enable the `wr-*` commands
- `scripts/` - PowerShell scripts that do the actual work
- `.env` - Your local vault configuration (gitignored)
```

## Typical Workflow

```bash
# One-time setup
wr-setup

# Add secrets for your API resource
wr-save -Resource myapi -Name api-key -EnvVarName MYAPI_API_KEY
wr-save -Resource myapi -Name api-secret -EnvVarName MYAPI_API_SECRET
wr-save -Resource myapi -Name endpoint -EnvVarName MYAPI_ENDPOINT

# Add secrets for database
wr-save -Resource database -Name connection-string -EnvVarName DATABASE_CONNECTION_STRING
wr-save -Resource database -Name password -EnvVarName DATABASE_PASSWORD

# View what's configured
wr-list

# When running tests
wr-load -Resource "myapi,database"
npm test  # or your test command

# Clean up
wr-clear
```

## Security Notes

- **Never commit secrets**: Secret values are stored only in KeyVault, not locally
- **Use interactive input**: Prefer prompted input over `-Value` parameter to keep secrets out of shell history
- **Session isolation**: Consider `-SpawnShell` for extra isolation; exit returns to clean session
- **RBAC permissions**: The setup script uses "Key Vault Secrets Officer" role (least privilege for this use case)
- **Tags as metadata**: Environment variable names are stored as tags on the secrets in KeyVault

## Troubleshooting

### "Vault not found" error
Run `wr-setup` to create the vault.

### "Access denied" error
Run `wr-setup -Force` to re-apply permissions.

### "az: command not found"
Install Azure CLI for your platform (see Prerequisites).

### Secrets not loading / "missing env-var-name tag"
1. Run `wr-list` to see secrets and their tags
2. Ensure you're logged in: `az account show`
3. Verify vault name in `.env`

## Maintenance Scripts

### `migrate-secrets.ps1`

A utility script for migrating secrets that are missing required tags (`env-var-name` and `resource`). This is useful for:

- Cleaning up secrets created before the tag-based system
- Fixing secrets with missing or incomplete tags
- Bulk-tagging existing secrets

```powershell
# Preview what needs migration
./scripts/migrate-secrets.ps1 -DryRun

# Run migration interactively
./scripts/migrate-secrets.ps1

# Skip confirmation prompts (still prompts for tag values)
./scripts/migrate-secrets.ps1 -Force
```

> **Note:** This script is not part of the `wr-*` CLI suite—it's a one-off maintenance tool.

## License

MIT
