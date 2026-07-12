# Rails Encrypted Credentials

This directory contains environment-specific encrypted credential files for storing secrets.

## Files

- `development.yml.enc` - Encrypted credentials for development environment
- `staging.yml.enc` - Encrypted credentials for staging environment
- `production.yml.enc` - Encrypted credentials for production environment
- `test.yml.enc` - Encrypted credentials for test environment
- `*.key` - Encryption keys (never commit these to git)

## Editing Credentials

To edit credentials for a specific environment:

```bash
# Development
EDITOR="code --wait" bin/rails credentials:edit -e development

# Staging
EDITOR="code --wait" bin/rails credentials:edit -e staging

# Production
EDITOR="code --wait" bin/rails credentials:edit -e production

# Test
EDITOR="code --wait" bin/rails credentials:edit -e test
```

**Note:** The `--wait` flag is required so VS Code blocks until you close the file. Without it, Rails will re-encrypt the file before you have a chance to edit it.

## Expected Format

The credentials file should contain an `mcp_secrets` array:

```yaml
mcp_secrets:
  - name: API_KEY
    value: your_api_key_here
    description: Optional description of what this secret is for
  - name: ANOTHER_SECRET
    value: secret_value
    description: Another optional description
```

## Usage in Code

Secrets are loaded via the `SecretsLoader` service:

```ruby
# Get a secret value (returns nil if not found)
SecretsLoader.get("API_KEY")

# Get a secret value (raises error if not found)
SecretsLoader.get!("API_KEY")

# Check if a secret exists
SecretsLoader.exists?("API_KEY")

# Get all secrets
SecretsLoader.all

# Check if credentials are available
SecretsLoader.available?
```

## Key Management

Keep the `development.key`, `staging.key`, and `production.key` files in your password manager. They
are the only way to read the encrypted credentials, and they are not in git.

The key is supplied **either** as the matching `config/credentials/<env>.key` file **or** through the
`RAILS_MASTER_KEY` environment variable — that one variable, for every environment. Rails hardcodes
the name (`Rails::Application#encrypted` defaults `env_key: "RAILS_MASTER_KEY"`), so it is
`RAILS_MASTER_KEY` that unlocks `staging.yml.enc` when `RAILS_ENV=staging`, and `production.yml.enc`
when `RAILS_ENV=production`. There is no per-environment env var; a name like
`RAILS_CREDENTIALS_STAGING_KEY` is read by nothing.

Blank is the same as absent: ActiveSupport reads it as `ENV["RAILS_MASTER_KEY"].presence`. So an
unset key does not crash the app — the credentials simply stay encrypted and `SecretsLoader` serves
nothing.

## How each environment gets its key

| Environment | `.enc` file | Where the key comes from |
| --- | --- | --- |
| development / test | in git | your local `config/credentials/<env>.key` (from the password manager) |
| staging | `staging.yml.enc`, **in git** | the `STAGING_RAILS_MASTER_KEY` GitHub Actions secret → `RAILS_MASTER_KEY` via `.kamal/secrets.staging` |
| production | **not** in git — bind-mounted onto the droplet at `/opt/zimmer/credentials` | the `PROD_RAILS_MASTER_KEY` secret → `RAILS_MASTER_KEY` via `.kamal/secrets.production` |

Staging's key is optional: a deploy without it boots fine, but Slack and every credential-bearing MCP
server go quiet. `deploy-staging.yml` warns rather than fails.

## Creating Staging Credentials

`staging.yml.enc` already exists. To edit it you need `staging.key` (in the password manager as
*Zimmer staging RAILS_MASTER_KEY*); drop it at `config/credentials/staging.key` and run:

```bash
EDITOR="code --wait" bin/rails credentials:edit -e staging
```

If you are standing up your own fork and have no `staging.yml.enc`, that same command creates both
the `.enc` and a fresh `.key`. Then put the key in your password manager and set it as the
`STAGING_RAILS_MASTER_KEY` GitHub Actions secret (`gh secret set STAGING_RAILS_MASTER_KEY < config/credentials/staging.key`).

## Security Notes

- The `.key` files are excluded from git via `.gitignore`
- Never share or commit encryption keys
- In CI/staging/production, set the key via the `RAILS_MASTER_KEY` environment variable (Kamal
  injects it as a secret), or deploy the key file separately
