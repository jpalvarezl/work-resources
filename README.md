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
| `wr-save` | Save a new secret to KeyVault |
| `wr-update` | Update an existing secret (value and/or env var name) |
| `wr-load` | Load secrets into environment |
| `wr-list` | List secrets in KeyVault |
| `wr-delete` | Delete a secret from KeyVault |
| `wr-clear` | Clear secrets from environment |
| `wr-add-user` | Grant vault access to a teammate |
| `wr-migrate` | Backfill tags on legacy untagged secrets |

### `wr-setup`

First-time setup and vault creation.

```powershell
wr-setup                # Create vault (new) or join existing vault (read-only)
wr-setup -Role Admin    # Join existing vault with write access
wr-setup -Force         # Re-apply permissions
```

When creating a **new** vault, you're automatically assigned the Admin role (Key Vault Secrets Officer). When joining an **existing** vault, you get the User role (Key Vault Secrets User) by default — use `-Role Admin` to request write access.

### `wr-save`

Add or update a secret in KeyVault.

```powershell
wr-save -Resource <name> -Name <secret-name> -EnvVarName <env-var> [-Value <value>] [-Flavor <flavor>]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource prefix (e.g., "myapi", "database"). Must start with a letter and contain only letters, numbers, and hyphens (no underscores). |
| `-Name` | Yes | Secret name (e.g., "api-key", "connection-string"). Same naming rules as Resource. |
| `-EnvVarName` | Yes | Environment variable name (e.g., "MYAPI_API_KEY"). Must start with a letter/underscore and contain only letters, numbers, and underscores. |
| `-Value` | No | Secret value (prompts if not provided) |
| `-Flavor` | No | Optional flavor label (e.g., "py", "base", "superset"). When set, secret name becomes `{Resource}-{Flavor}-{Name}` and a `flavor` tag is added so `wr-load -Flavor <name>` can filter. Must be lowercase, start with a letter, and contain only letters, digits, and internal hyphens. |

**Naming**: The secret is stored in KeyVault as `{resource}-{name}` (or `{resource}-{flavor}-{name}` when `-Flavor` is set) with an `env-var-name` tag.
- Example: `wr-save -Resource myapi -Name api-key -EnvVarName MYAPI_API_KEY`
- KeyVault secret name: `myapi-api-key`
- Tag: `env-var-name=MYAPI_API_KEY`

With flavor:
- Example: `wr-save -Resource foundry-sdk-deployment -Flavor py -Name foundry-project-endpoint -EnvVarName FOUNDRY_PROJECT_ENDPOINT`
- KeyVault secret name: `foundry-sdk-deployment-py-foundry-project-endpoint`
- Tags: `resource=foundry-sdk-deployment`, `flavor=py`, `env-var-name=FOUNDRY_PROJECT_ENDPOINT`

### `wr-update`

Update an existing secret in KeyVault. The `-Name` parameter is the actual KeyVault secret name. The updated value is also set in your current shell session.

```powershell
wr-update -Resource <resource> -Name <secret-name> [-EnvVarName <env-var>] [-Value <value>] [-Flavor <flavor>]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | The resource tag to filter by (e.g., "azure-agents", "myapp") |
| `-Name` | Yes | The actual secret name in KeyVault (e.g., "azure-agents-endpoint") |
| `-EnvVarName` | No | Update the environment variable name tag (keeps existing if omitted) |
| `-Value` | No | New secret value (prompts if not provided) |
| `-Flavor` | No | Update the `flavor` tag. Preserves the existing flavor if omitted. |

**Examples**:
```powershell
wr-update -Resource azure-agents -Name azure-agents-endpoint                  # Prompt for new value
wr-update -Resource azure-agents -Name azure-agents-endpoint -Value "newval"  # Set value directly
wr-update -Resource myapp -Name myapp-api-key -EnvVarName "NEW_VAR"           # Also change env var name
wr-update -Resource foundry-sdk-deployment -Name foundry-sdk-deployment-py-foundry-project-endpoint -Flavor py -Value "..."
```

### `wr-load`

Load secrets into current session as environment variables.

```powershell
wr-load [-Resource <name>] [-Flavor <flavor>] [-Name <name>] [-Export <shell>] [-SpawnShell] [-NoEnvFile]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | No | Resource prefix(es) to filter (loads all if omitted) |
| `-Flavor` | No | Flavor(s) to filter, comma-separated. When set, only secrets whose `flavor` tag matches are loaded; legacy untagged secrets are excluded. |
| `-Name` | No | Narrow to a single secret by its short name. Requires `-Resource` and accepts at most one `-Resource` / one `-Flavor`. Matches the composed KV name `{Resource}-{Name}` (or `{Resource}-{Flavor}-{Name}` when `-Flavor` is set). |
| `-Export` | No | Output format: `bash`, `zsh`, `fish`, `powershell` |
| `-SpawnShell` | No | Spawn new shell with secrets (isolated) |
| `-NoEnvFile` | No | Skip writing to `./.env`. By default `wr-load` always persists the loaded values to a fenced block in `./.env` so subsequent ephemeral shell commands can pick them up. |

**Examples**:
```powershell
wr-load                                              # Load all secrets
wr-load -Resource myapi                              # Filter by resource
wr-load -Resource "myapi,shared"                     # Multiple resources
wr-load -Resource foundry-sdk-deployment -Flavor py  # Resource + flavor
wr-load -Resource foundry-sdk-deployment -Flavor "py,js"
wr-load -Resource foundry-sdk-deployment -Flavor py -Name foundry-project-endpoint   # Single secret
wr-load -Resource myapi -SpawnShell                  # Isolated shell
```

When `-Flavor` is omitted and the selected secrets contain multiple flavors mapping
to the same env var name (e.g., `FOUNDRY_PROJECT_ENDPOINT` in both `.env` and
`.py.env`), `wr-load` prints a collision warning and the last-loaded value wins.
Use `-Flavor` to disambiguate.

#### Persisting to `./.env` (bridging ephemeral shells)

In addition to setting secrets as in-process environment variables, `wr-load`
**always also writes** them to `./.env` in the current working directory.
This bridges the common AI-agent workflow where each tool call spawns a fresh
shell — the in-process env vars from one call don't survive to the next, but
the on-disk `.env` does.

The block is fenced so it can be updated cleanly and coexist with any pre-existing
`.env` content the project already has:

```dotenv
USER_VAR=keep_me                       # your content — never touched
# >>> work-resources >>>
FOUNDRY_PROJECT_ENDPOINT='...'
FOUNDRY_MODEL_NAME='...'
# ...
# <<< work-resources <<<
```

- A subsequent `wr-load` **replaces** the fenced block (does not accumulate).
- `wr-clear` **removes** the fenced block. Content outside the fences is always
  preserved.
- Pass `-NoEnvFile` on either command to opt out of the file write/removal.

How to consume the file from a subsequent shell command:

```bash
# bash / zsh
set -a; source ./.env; set +a; <your-command>
```

```fish
# fish
for line in (cat ./.env | grep -v '^#' | grep '='); set -gx (string split -m1 = $line); end; <your-command>
```

For **PowerShell**, the values are written in POSIX single-quoted form
(`KEY='value'`, with embedded quotes escaped as `'\''`). A naive parser
that just trims quote characters will mis-decode any value containing a
literal single quote, so use the `bash`/`zsh` snippet above when possible,
or run `wr-load` directly in your pwsh session — it sets the env vars
in-process so no separate source step is needed.

Some tools support auto-loading `./.env` natively or via a plugin, but
behaviour varies a lot — some load it unconditionally, some only with a
specific filename or prefix, some require explicit configuration, and
some don't read `.env` at all. **Consult your tool's docs rather than
assuming.** When in doubt, the explicit `set -a; source ./.env; set +a`
form above works universally for any process you launch from bash/zsh.

> **Security**: secrets are now on disk as plaintext. Ensure `./.env` is
> gitignored (most projects' `.gitignore` covers `.env` by default — verify
> in yours). The fenced block convention uses the exact comment string
> `# >>> work-resources >>>`, so it won't collide with any other tool's
> markers.

### `wr-list`

Display secrets in KeyVault, grouped by resource and then by flavor.

```powershell
wr-list [-Resource <name>] [-Flavor <flavor>] [-Name <name>]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | No | Filter by resource tag (comma-separated list allowed) |
| `-Flavor` | No | Filter by flavor tag (comma-separated list allowed) |
| `-Name` | No | Narrow to a single secret by its short name. Requires single-token `-Resource` and at most one `-Flavor`. |

```powershell
wr-list                                              # All secrets, grouped by resource and flavor
wr-list -Resource myapi                              # Filter by resource
wr-list -Resource "myapi,shared"                     # Multiple resources
wr-list -Resource foundry-sdk-deployment -Flavor py  # Resource + flavor
wr-list -Resource foundry-sdk-deployment -Flavor py -Name foundry-project-endpoint   # Single secret
```

### `wr-clear`

Remove loaded secrets from current session.

```powershell
wr-clear                    # Clear all (prompts)
wr-clear -Resource myapi    # Clear by resource
wr-clear -Resource foundry-sdk-deployment -Flavor py
wr-clear -Resource foundry-sdk-deployment -Flavor py -Name foundry-project-endpoint -Force   # Single env var
wr-clear -Force             # Skip confirmation
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | No | Restrict to env vars whose secrets are tagged with the given resource |
| `-Flavor` | No | Restrict to env vars whose secrets are tagged with the given flavor(s) |
| `-Name` | No | Narrow to the single env var that the composed secret name maps to: `{Resource}-{Name}` (unflavored) or `{Resource}-{Flavor}-{Name}` (flavored). Requires single-token `-Resource` and at most one `-Flavor`. |
| `-Force` | No | Skip confirmation |
| `-NoEnvFile` | No | Skip removing the fenced block from `./.env`. By default `wr-clear` removes that block (in addition to unsetting in-process env vars) so the on-disk file and the in-process state stay in sync. |

> **Note:** `-Flavor` narrows the *configured* env var names to clear. The OS does not record which flavor originally populated an env var, so if you loaded `FOUNDRY_PROJECT_ENDPOINT` from `flavor=java` and then run `wr-clear -Flavor py`, the var will still be unset (the configured name matches).

### `wr-delete`

Delete secrets from KeyVault.

```powershell
wr-delete -Resource <name> -Name <secret-name> [-Flavor <flavor>] [-Force]
wr-delete -Resource <name> -All [-Flavor <flavor>] [-Force]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Resource` | Yes | Resource prefix |
| `-Name` | No* | Secret name to delete (*required unless -All is used) |
| `-All` | No | Delete all secrets with the resource prefix |
| `-Flavor` | No | When used with `-Name`: composes `{Resource}-{Flavor}-{Name}` and verifies the secret's `flavor` tag matches before deleting. When used with `-All`: filters to secrets whose `flavor` tag matches (comma-separated list allowed). |
| `-Force` | No | Skip confirmation prompt |

**Examples**:
```powershell
wr-delete -Resource myapi -Name api-key                                  # Delete single secret
wr-delete -Resource myapi -All                                           # Delete all myapi-* secrets
wr-delete -Resource myapi -All -Force                                    # No confirmation
wr-delete -Resource foundry-sdk-deployment -Flavor py -Name endpoint     # Delete foundry-sdk-deployment-py-endpoint (verifies tags)
wr-delete -Resource foundry-sdk-deployment -All -Flavor py -Force        # Delete every py-flavored secret in foundry-sdk-deployment
```

### `wr-add-user`

Grant or remove vault access for a teammate. Only admins (Key Vault Secrets Officer) can run this.

```powershell
wr-add-user -Email <user-email> [-Role <Admin|User>] [-Remove]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Email` | Yes | The user's email (Azure AD UPN) |
| `-Role` | No | `User` (read-only, default) or `Admin` (read + write) |
| `-Remove` | No | Remove the user's access instead of granting it |

**Examples**:
```powershell
wr-add-user -Email teammate@company.com                # Grant read-only access
wr-add-user -Email teammate@company.com -Role Admin     # Grant full access
wr-add-user -Email teammate@company.com -Remove         # Revoke access
```

## RBAC Roles

The tool uses Azure RBAC with two roles:

| Role | Azure Role Name | Can do |
|------|----------------|--------|
| **User** | Key Vault Secrets User | `wr-load`, `wr-list`, `wr-clear` |
| **Admin** | Key Vault Secrets Officer | All commands including `wr-save`, `wr-update`, `wr-delete`, `wr-add-user` |

- **Vault creator** is always assigned Admin automatically
- **Team members** joining an existing vault get User (read-only) by default
- Admins can promote others with `wr-add-user -Email user@company.com -Role Admin`

## Flavors: mirroring multi-file env structures

When a project keeps several env files in one folder — e.g.

```
.azure/foundry-sdk-deployment/
├── .env
├── .superset.env
├── .java.env
├── .js.env
├── .net.env
└── .py.env
```

the same env var (say `FOUNDRY_PROJECT_ENDPOINT`) may appear in multiple files
with different intended audiences. The `-Flavor` parameter lets you store each
file's content separately and then load exactly the subset you need.

**Convention**: filename suffix → flavor label.

| File | Flavor |
|------|--------|
| `.env` | `base` |
| `.superset.env` | `superset` |
| `.py.env` | `py` |
| `.js.env` | `js` |
| `.net.env` | `net` |
| `.java.env` | `java` |

A flavor must be lowercase, start with a letter, and contain only letters,
digits, and internal hyphens (`^[a-z]([a-z0-9-]*[a-z0-9])?$`).

When `-Flavor` is set on `wr-save`, the secret name becomes
`{resource}-{flavor}-{name}` and a `flavor` tag is added alongside `resource`
and `env-var-name`. `wr-load`, `wr-list`, `wr-clear`, and `wr-delete` all accept
`-Flavor` to filter by it. Legacy secrets without a `flavor` tag continue to
work; they are simply excluded when `-Flavor` is explicitly requested.

**Example workflow** for the directory above:

```powershell
# Save FOUNDRY_PROJECT_ENDPOINT once per flavor it appears in
wr-save -Resource foundry-sdk-deployment -Flavor base     -Name foundry-project-endpoint -EnvVarName FOUNDRY_PROJECT_ENDPOINT
wr-save -Resource foundry-sdk-deployment -Flavor superset -Name foundry-project-endpoint -EnvVarName FOUNDRY_PROJECT_ENDPOINT
wr-save -Resource foundry-sdk-deployment -Flavor py       -Name foundry-project-endpoint -EnvVarName FOUNDRY_PROJECT_ENDPOINT

# Load only what .py.env contained
wr-load -Resource foundry-sdk-deployment -Flavor py

# Load .env's worth (the azd outputs)
wr-load -Resource foundry-sdk-deployment -Flavor base

# Inspect what's stored, grouped by flavor under each resource
wr-list -Resource foundry-sdk-deployment

# Delete every py-flavored secret for this deployment
wr-delete -Resource foundry-sdk-deployment -All -Flavor py -Force
```

> **Collision warning**: If you call `wr-load -Resource X` without `-Flavor` and
> the matched secrets contain the same env var name across multiple flavors,
> `wr-load` prints a warning and the last-loaded value wins. Use `-Flavor` to
> disambiguate.

## Project Structure

```
.
├── bin/                              # Shell wrappers that enable the `wr-*` commands
├── scripts/                          # PowerShell scripts that do the actual work
├── tests/                            # Pester unit tests
├── .agent/skills/work-resources/     # SKILL.md guide for AI coding agents
├── .env.template                     # Seed config (copy to .env, gitignored)
├── install.ps1 / install.sh          # Cross-platform installer
└── uninstall.ps1 / uninstall.sh      # Uninstaller
```

After install (`./install.ps1`), the runtime config and a copy of the scripts
live at `~/.work-resources/` (or `%USERPROFILE%\.work-resources\` on Windows).
Edit `~/.work-resources/config/.env` to change vault, resource group, or
subscription.

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
- **RBAC permissions**: Two roles for least-privilege access:
  - **Key Vault Secrets User** (read-only) for team members who only need to load secrets
  - **Key Vault Secrets Officer** (read + write) for admins who manage secrets
- **Write protection**: `wr-save`, `wr-update`, and `wr-delete` check for Officer role before executing
- **Tags as metadata**: Environment variable names are stored as tags on the secrets in KeyVault

## Running Tests

The project uses [Pester](https://pester.dev/) (v5+) for unit testing. Tests are in the `tests/` directory.

```powershell
# Run all tests
Import-Module Pester -MinimumVersion 5.0 -Force
Invoke-Pester ./tests

# Run with detailed output
Invoke-Pester ./tests -Output Detailed

# Run a specific test file
Invoke-Pester ./tests/common.Tests.ps1
```

### Prerequisites

- **Pester 5+**: Install or update with:
  ```powershell
  Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
  ```

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

### `wr-migrate`

A utility command for migrating secrets that are missing required tags
(`env-var-name` and `resource`). Useful for:

- Cleaning up secrets created before the tag-based system
- Fixing secrets with missing or incomplete tags
- Bulk-tagging existing secrets

```powershell
# Preview what needs migration
wr-migrate -DryRun

# Run migration interactively (prompts for each missing tag)
wr-migrate

# Skip the up-front "proceed?" confirmation (still prompts per-secret for tag values)
wr-migrate -Force
```

> Requires the Officer role. Prompts interactively for tag values, so do not invoke unattended unless you can answer the prompts.

## License

MIT
