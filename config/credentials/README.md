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

**Tadas has the `development.key`, `staging.key`, and `production.key` secrets saved in 1Password.**

For local development, these keys should also be stored in `~/github-projects/agents/.env`:
```
RAILS_CREDENTIALS_DEVELOPMENT_KEY=<development.key contents>
RAILS_CREDENTIALS_STAGING_KEY=<staging.key contents>
RAILS_CREDENTIALS_PRODUCTION_KEY=<production.key contents>
```

## Creating Staging Credentials

If the `staging.yml.enc` file doesn't exist yet, create it:

```bash
# This creates both staging.yml.enc and staging.key
EDITOR="code --wait" bin/rails credentials:edit -e staging
```

Copy the generated `staging.key` file content to:
1. 1Password (for team access)
2. The staging server at `/home/deploy/staging.key`
3. Your local `.env` file as `RAILS_CREDENTIALS_STAGING_KEY`

## Security Notes

- The `.key` files are excluded from git via `.gitignore`
- Never share or commit encryption keys
- In CI/staging/production, set the key via environment variable (e.g., `RAILS_CREDENTIALS_STAGING_KEY` or `RAILS_CREDENTIALS_PRODUCTION_KEY`) or deploy the key file separately
