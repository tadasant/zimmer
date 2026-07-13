---
title: The private companion repo
description: How to structure the private "-internal" repo that pairs with Zimmer — one AIR catalog plus a deployment directory per service, each pairing Terraform with production tfvars and a Kamal deploy workflow.
sidebar:
  order: 3
---

This repo — the public Zimmer app — is deliberately a **public-safe template**. It ships
`config/deploy.yml` / `config/deploy.staging.yml`, a `staging.tfvars.example`, and a
self-contained AIR catalog you can resolve offline. What it does **not** carry is your
production reality: your real hostnames, your production tfvars, the secrets those workflows
consume, and the agent-root catalog you actually run sessions against.

That reality belongs in a **second, private repo** — the companion. The pattern is one
private `-internal` repo that holds two things:

1. **One AIR catalog** (`artifacts/`) — the agent roots, MCP servers, skills, and references
   your sessions really use, resolved by Zimmer at runtime.
2. **A deployment directory per service** — each pairing Terraform, a production tfvars, and
   a Kamal-style deploy workflow. Zimmer is one of those services; anything else you run on
   the same pattern (observability, a CI runner, another app) is a sibling directory.

Keeping it private is the point: it is where real hostnames, cloud tokens, and encrypted
credentials live. The public repo stays forkable; the private repo stays yours.

:::note[Everything below is a template]
The names, hostnames, and values here are **placeholders**. Replace `<owner>`,
`<your-org>-internal`, `<service>`, and every `example.com` / `changeme` with your own. Nothing
in this page reflects a real deployment.
:::

## Recommended folder hierarchy

```
<your-org>-internal/                 # PRIVATE repo — never goes public
├── README.md                        # what this repo is; how to deploy each service
├── .github/
│   └── workflows/
│       ├── deploy-zimmer.yml         # per-service deploy pipelines (Terraform + Kamal)
│       ├── deploy-obs.yml
│       └── deploy-ci-runner.yml
│
├── artifacts/                        # the ONE production AIR catalog
│   ├── air.json                      # top-level catalog: points at the indexes below
│   ├── roots.json                    # agent-root definitions (your real roots)
│   ├── mcp.json                      # MCP server registry
│   ├── skills/
│   │   ├── skills.json               # skills index
│   │   └── <skill-id>/SKILL.md       # one directory per skill
│   ├── references/
│   │   ├── references.json           # references index
│   │   └── <name>.md
│   └── agent-roots/                  # per-root working trees the roots clone into
│       └── <root-id>/
│           └── CLAUDE.md             # root-specific agent instructions
│
├── zimmer/                          # ── one deployment directory per service ──
│   ├── terraform/
│   │   ├── main.tf                   # host provisioning (usually a thin module wrapper)
│   │   ├── variables.tf
│   │   ├── backend.hcl               # remote state config (bucket, key, region)
│   │   └── production.tfvars         # real host values — PRIVATE
│   ├── deploy.production.yml         # Kamal production destination (overrides the public base)
│   └── .kamal/
│       └── secrets.production        # maps Kamal secrets to env / a secrets manager
│
├── obs/                             # a sibling service (observability), same shape
│   ├── terraform/{main.tf,variables.tf,backend.hcl,production.tfvars}
│   ├── deploy.production.yml
│   └── .kamal/secrets.production
│
├── ci-runner/                      # another sibling (self-hosted CI runner)
│   ├── terraform/{...}
│   └── ...
│
└── <service>/                      # copy this shape for each new service
    └── ...
```

Two organizing rules make this scale:

- **The catalog is singular; deployments are plural.** There is exactly one `artifacts/`
  tree — the source of truth for what your agents can do — and one directory per host/service
  you deploy. A new service is a new top-level directory, never a new catalog.
- **Every deployment directory has the same three parts:** `terraform/` (the host),
  `deploy.production.yml` (the app on the host, via Kamal), and `.kamal/secrets.production`
  (how secrets reach Kamal). Once you know one, you know all of them.

## How the two repos connect

Zimmer resolves its catalog through the `AIR_CONFIG` environment variable. Point it at the
companion repo's `artifacts/air.json` and Zimmer runs against your real roots instead of the
public repo's self-contained sample catalog. An agent root in `roots.json` names a `url` and
optional `subdirectory`; that is the repo (public or private) a session clones when it runs
that root.

```
Public repo (tadasant/zimmer)          Private repo (<your-org>-internal)
────────────────────────────           ──────────────────────────────────
Docker image + deploy.yml base   ◀──── zimmer/deploy.production.yml (destination override)
self-contained sample catalog          artifacts/air.json  ◀── AIR_CONFIG points here in prod
                                        artifacts/roots.json → each root's url + subdirectory
```

## Copyable templates

Trim to taste; the comments explain each choice. None of the values are real.

### `artifacts/air.json`

The top-level catalog. Mirrors the public repo's `air.json`, but points at *your* indexes.

```json
{
  "$schema": "https://pulsemcp.github.io/air/schemas/air.schema.json",
  "name": "<your-org>-catalog",
  "description": "Production AIR catalog for <your-org>. Resolved by Zimmer via AIR_CONFIG.",
  "gitProtocol": "https",
  "extensions": [
    "@pulsemcp/air-adapter-claude",
    "@pulsemcp/air-secrets-env"
  ],
  "skills": ["./skills/skills.json"],
  "mcp": ["./mcp.json"],
  "roots": ["./roots.json"],
  "references": ["./references/references.json"]
}
```

### `artifacts/roots.json`

One entry per agent root. `url` is the repo a session clones; `subdirectory` scopes it to a
path within that repo. Set `default_goal` to a goal id your Zimmer instance defines.

```json
{
  "$schema": "https://pulsemcp.github.io/air/schemas/roots.schema.json",
  "<service>": {
    "name": "<service>",
    "display_name": "<Service>",
    "description": "The <service> app — models, jobs, services, tests.",
    "url": "https://github.com/<owner>/<service>.git",
    "default_branch": "main",
    "user_invocable": true,
    "default_goal": "open-reviewed-green-pr"
  },
  "ops": {
    "name": "ops",
    "display_name": "Production Ops",
    "description": "This private repo's deployment layer: tfvars, deploy workflows, the Terraform modules.",
    "url": "https://github.com/<owner>/<your-org>-internal.git",
    "default_branch": "main",
    "user_invocable": true,
    "subdirectory": "<service>"
  }
}
```

### `<service>/terraform/production.tfvars` — PRIVATE

The values Terraform provisions the host with. This file never leaves the private repo.

```hcl
environment  = "production"
region       = "nyc3"
droplet_size = "s-2vcpu-4gb"

# Custom-domain HTTPS over the tailnet (optional). "" = plain HTTP, tailnet-only.
domain = "<service>.example.com"

# Operator/tooling public keys cloud-init authorizes for root, on top of the deploy key.
# Set per environment — NEVER as a module default — so a fork can't authorize a stray key.
admin_ssh_pubkeys = [
  "ssh-ed25519 AAAA...replace-with-your-own-key you@example.com",
]

# Set for production (managed database); leave "" to run a throwaway Postgres accessory.
managed_db_cluster_name = "<service>-prod-db"
```

### `<service>/terraform/backend.hcl`

Remote state, so `terraform apply` in CI is not tied to one laptop.

```hcl
bucket   = "<your-org>-tfstate"
key      = "<service>/production.tfstate"
region   = "nyc3"
endpoint = "https://nyc3.digitaloceanspaces.com"   # or your S3-compatible endpoint
```

### `<service>/deploy.production.yml`

The Kamal **production destination**. Kamal merges a destination file with the base
`config/deploy.yml` when you pass `-d <dest>` — but it looks for both **side by side** in
one checkout (`config/deploy.yml` + `config/deploy.production.yml`); it will not merge a file
from a second repo, and passing `-c` twice keeps only the last file rather than merging. So at
deploy time this file has to sit next to the public base as `config/deploy.production.yml`
(the deploy job below checks out the public repo and drops this file in). Kept private because
it names real hosts.

```yaml
# Merged with the public repo's config/deploy.yml via `kamal deploy -d production`
# (both files must be present in the deploy checkout — see the deploy job below).
service: <service>
# Repository path only — Kamal prepends registry.server below, so this resolves to
# ghcr.io/<owner>/<service>. Including the registry here would double it.
image: <owner>/<service>

servers:
  web:
    hosts:
      - <service>-prod            # tailnet MagicDNS name or private IP — never public
  worker:
    hosts:
      - <service>-prod
    cmd: bundle exec good_job start

registry:
  server: ghcr.io
  username: <owner>
  password:
    - KAMAL_REGISTRY_PASSWORD

env:
  clear:
    RAILS_ENV: production
    AIR_CONFIG: /home/rails/artifacts/air.json   # point Zimmer at THIS repo's catalog
  secret:
    - SECRET_KEY_BASE
    - DATABASE_PASSWORD
```

### `<service>/.kamal/secrets.production`

How Kamal resolves the `secret:` names above. Pull them from your secrets manager or CI
environment — **never commit the values themselves**.

```bash
# Resolved at deploy time. Each name here must already be set in the environment Kamal
# runs in — the deploy job below exports them from GitHub Actions secrets (or pull them
# from a secrets manager, e.g. `op read ...` with the 1Password CLI). This file is just
# the wiring: `NAME=$NAME` passes an env var straight through to Kamal's secret store.
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
SECRET_KEY_BASE=$SECRET_KEY_BASE
DATABASE_PASSWORD=$DATABASE_PASSWORD
```

### `.github/workflows/deploy-<service>.yml`

One pipeline per service: provision the host with Terraform, then ship the app with Kamal.
Manual dispatch keeps production deploys deliberate.

```yaml
name: Deploy <service>
on:
  workflow_dispatch:
    inputs:
      ref:
        description: "Branch/tag/SHA to build & deploy"
        required: false
        default: "main"

concurrency:
  group: <service>-production
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Terraform apply (host)
        working-directory: <service>/terraform
        env:
          # Secrets live in GitHub Actions, never in the repo.
          TF_VAR_do_token: ${{ secrets.DIGITALOCEAN_ACCESS_TOKEN }}
          AWS_ACCESS_KEY_ID: ${{ secrets.SPACES_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.SPACES_SECRET_ACCESS_KEY }}
        run: |
          terraform init -backend-config=backend.hcl
          terraform apply -auto-approve -var-file=production.tfvars

      - name: Kamal deploy (app)
        # Kamal's `-d production` merges config/deploy.yml with config/deploy.production.yml
        # from the SAME checkout, so check out the public app repo and drop this service's
        # destination file into it as config/deploy.production.yml before deploying. The env
        # names below are exactly the ones .kamal/secrets.production passes through to Kamal.
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GHCR_PULL_TOKEN }}
          SECRET_KEY_BASE: ${{ secrets.PROD_SECRET_KEY_BASE }}
          DATABASE_PASSWORD: ${{ secrets.PROD_DB_PASSWORD }}
        run: |
          git clone https://github.com/<owner>/<service>.git app && cd app
          cp ../<service>/deploy.production.yml   config/deploy.production.yml
          cp ../<service>/.kamal/secrets.production .kamal/secrets.production
          gem install kamal
          kamal deploy -d production
```

## Checklist for a new service

1. Copy an existing service directory (`zimmer/`) to `<service>/`.
2. Update `terraform/production.tfvars` (hostname, size, domain) and `backend.hcl` (state key).
3. Point `deploy.production.yml` at the new hosts and image.
4. Add the `secret:` names your app needs to `.kamal/secrets.production` and the matching
   GitHub Actions secrets.
5. Copy `deploy-zimmer.yml` to `deploy-<service>.yml` and swap the directory names.
6. If the service runs agent sessions, add a root for it to `artifacts/roots.json`.

Keep the shape identical across services. The consistency is what lets one deploy workflow —
and one mental model — cover everything you run.
