# Zimmer infrastructure on DigitalOcean.
#
# One droplet running the Zimmer stack (app + Postgres + Redis via docker
# compose), joined to a Tailscale tailnet so the UI is reachable ONLY over the
# VPN — there is no public ingress to the app port. The same module is used for
# staging and production; the difference is entirely in *.tfvars.
#
# Nothing secret lives in this file. Secrets (DO token, Tailscale auth key, GHCR
# pull token) are passed as TF variables, which in CI come from GitHub Actions
# secrets and locally from your shell (TF_VAR_*).

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.43"
    }
  }
  # Configure a remote backend (e.g. DO Spaces via the S3 backend) per
  # environment so state is shared with CI. Left unconfigured here so the
  # template is portable; see infra/terraform/README.md.
}

provider "digitalocean" {
  token = var.do_token
}

# ---- Variables --------------------------------------------------------------

variable "do_token" {
  type        = string
  sensitive   = true
  description = "DigitalOcean API token (TF_VAR_do_token; a GH Actions secret in CI)."
}

variable "environment" {
  type        = string
  description = "staging or production."
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be 'staging' or 'production'."
  }
}

variable "region" {
  type        = string
  default     = "nyc3"
  description = "DigitalOcean region slug."
}

variable "droplet_size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Droplet size slug."
}

variable "image_ref" {
  type        = string
  default     = "ghcr.io/tadasant/zimmer:latest"
  description = "Full GHCR image ref to run."
}

variable "domain" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional FQDN for custom-domain HTTPS over the tailnet (e.g.
    zimmer.tadasant.com). When set, the droplet runs a Caddy TLS terminator on
    :443 for this name, reachable only over the tailnet like everything else.

    Caddy does NOT obtain its own certificate and the droplet holds NO DNS
    credential: the `domain-cert` workflow issues the cert out-of-band (ACME
    DNS-01, Cloudflare token confined to CI), registers the `domain -> tailnet
    IP` A record, and pushes only the cert onto the box. So this variable just
    turns the terminator on; the DNS record and cert are managed by that
    workflow, not by Terraform. Empty = plain HTTP over the tailnet only.
  EOT
}

variable "manage_project" {
  type        = bool
  default     = false
  description = <<-EOT
    Whether to create a dedicated DigitalOcean Project for this environment.
    Off by default: a DO Project name is account-unique, so under the CI deploy's
    ephemeral tfstate a re-run collides with the prior run's project (409 "name is
    already in use"). The droplet works fine in the account's default project.
    Enable only with a persistent tfstate backend that can reconcile the project.
  EOT
}

variable "ssh_key_fingerprints" {
  type        = list(string)
  default     = []
  description = "Fingerprints of DO-registered SSH keys allowed on the droplet."
}

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  description = "Tailscale (ephemeral, pre-authorized) auth key for the droplet to join the tailnet."
}

variable "ghcr_username" {
  type        = string
  description = "GHCR username used to pull the (initially private) image."
}

variable "ghcr_token" {
  type        = string
  sensitive   = true
  description = "GHCR read:packages token to pull the image on the droplet."
}

variable "secret_key_base" {
  type        = string
  sensitive   = true
  description = "Rails SECRET_KEY_BASE for the app."
}

# ---- Observability (all optional; empty = the app's obs initializers no-op) --

variable "otel_logs_endpoint" {
  type        = string
  default     = ""
  description = "OTLP/HTTP logs endpoint (e.g. https://obs.example.com/otel/v1/logs). Empty disables OTEL log shipping."
}

variable "otel_logs_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Bearer token for the OTLP logs endpoint. Both endpoint and token must be set to enable shipping."
}

variable "sentry_dsn" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Sentry/GlitchTip DSN for backend error tracking. Empty disables Sentry."
}

# ---- Managed database variables ----------------------------------------------

variable "managed_db_cluster_name" {
  type        = string
  default     = ""
  description = <<-EOT
    Name of an EXISTING DigitalOcean Managed Postgres cluster to use. Empty (the
    default, used by staging) means the compose stack runs its own throwaway
    Postgres container on the droplet's local disk. Set this in production so the
    database survives the droplet being reaped and re-created.
  EOT
}

variable "managed_db_username" {
  type        = string
  default     = "doadmin"
  description = "Database user on the managed cluster. Ignored unless managed_db_cluster_name is set."
}

variable "managed_db_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Password for managed_db_username (TF_VAR_managed_db_password; a GH Actions secret in CI)."
}

# ---- Managed database (read-only reference) ----------------------------------

# Deliberately a DATA SOURCE, never a managed resource.
#
# The droplet is cattle: `provision` reaps and re-creates it on every run, which
# destroys anything on its local disk. So the database must live OFF the droplet.
# But putting the cluster under Terraform management would hand this automation a
# destroy path to the one irreplaceable resource in the system -- and with the
# ephemeral tfstate these workflows use, Terraform would try to *create* it on
# every run and 409.
#
# A data source has no destroy path. Terraform can read the cluster's connection
# details and can never delete, replace, or resize it. Create/resize the cluster
# out of band (DigitalOcean console or API); its spec is documented in
# infra/terraform/data-stores/README.md.
data "digitalocean_database_cluster" "pg" {
  count = var.managed_db_cluster_name == "" ? 0 : 1
  name  = var.managed_db_cluster_name
}

# ---- Locals -----------------------------------------------------------------

locals {
  # The tailnet MagicDNS name you actually browse to. Production is simply
  # `zimmer` (http://zimmer); every other environment is suffixed
  # (http://zimmer-staging). Independent of the DigitalOcean droplet name and of
  # the tailnet ACL tag, both of which stay `zimmer-<environment>`.
  tailnet_hostname = var.environment == "production" ? "zimmer" : "zimmer-${var.environment}"

  # When a managed cluster is named, the app talks to it and the compose stack
  # ships no `db` service and no `pgdata` volume. Otherwise (staging, local) the
  # stack runs its own throwaway Postgres container.
  use_managed_db = var.managed_db_cluster_name != ""

  # Reach the cluster over DigitalOcean's private network so credentials never
  # traverse the public internet. The droplet is pinned into the cluster's VPC (see
  # `vpc_uuid` below), which is what makes `private_host` routable.
  db_host     = local.use_managed_db ? data.digitalocean_database_cluster.pg[0].private_host : "db"
  db_port     = local.use_managed_db ? data.digitalocean_database_cluster.pg[0].port : 5432
  db_username = local.use_managed_db ? var.managed_db_username : "zimmer"
  db_password = local.use_managed_db ? var.managed_db_password : var.secret_key_base

  # Managed Postgres mandates TLS. The compose Postgres does not speak it, so
  # staging/local fall back via "prefer".
  db_sslmode = local.use_managed_db ? "require" : "prefer"

  compose_depends_on = local.use_managed_db ? "[redis]" : "[db, redis]"
}

# ---- Resources --------------------------------------------------------------

resource "digitalocean_project" "zimmer" {
  count       = var.manage_project ? 1 : 0
  name        = "zimmer-${var.environment}"
  description = "Zimmer ${var.environment} environment."
  purpose     = "Web Application"
  environment = var.environment == "production" ? "Production" : "Staging"
  resources   = [digitalocean_droplet.zimmer.urn]
}

resource "digitalocean_droplet" "zimmer" {
  name     = "zimmer-${var.environment}"
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.droplet_size
  ssh_keys = var.ssh_key_fingerprints
  tags     = ["zimmer", "zimmer-${var.environment}"]

  # The app reaches the managed cluster over its PRIVATE host, which is only routable
  # from inside the cluster's VPC. Pin the droplet into that same VPC rather than
  # relying on both landing in the region's default VPC by coincidence. Null (the
  # staging path) lets DigitalOcean pick the region default.
  vpc_uuid = local.use_managed_db ? data.digitalocean_database_cluster.pg[0].private_network_uuid : null

  lifecycle {
    # Fail fast at plan time instead of booting a droplet that cannot authenticate and
    # only surfacing as a health-check timeout ~10 minutes later.
    precondition {
      condition     = !local.use_managed_db || var.managed_db_password != ""
      error_message = "managed_db_password must be set when managed_db_cluster_name is set (TF_VAR_managed_db_password, from the PROD_DB_PASSWORD secret)."
    }
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    environment        = var.environment
    tailnet_hostname   = local.tailnet_hostname
    use_managed_db     = local.use_managed_db
    db_host            = local.db_host
    db_port            = local.db_port
    db_username        = local.db_username
    db_password        = local.db_password
    db_sslmode         = local.db_sslmode
    compose_depends_on = local.compose_depends_on
    domain             = var.domain
    image_ref          = var.image_ref
    tailscale_auth_key = var.tailscale_auth_key
    ghcr_username      = var.ghcr_username
    ghcr_token         = var.ghcr_token
    secret_key_base    = var.secret_key_base
    otel_logs_endpoint = var.otel_logs_endpoint
    otel_logs_token    = var.otel_logs_token
    sentry_dsn         = var.sentry_dsn
  })
}

# Firewall: NO public app ingress. Only SSH (lock down to your admin CIDRs in
# tfvars if desired) and Tailscale's UDP. All app traffic rides the tailnet.
resource "digitalocean_firewall" "zimmer" {
  name        = "zimmer-${var.environment}"
  droplet_ids = [digitalocean_droplet.zimmer.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Tailscale coordination / direct connections.
  inbound_rule {
    protocol         = "udp"
    port_range       = "41641"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# No DNS record here. `var.domain`'s A record must point at the droplet's
# TAILNET IP (100.x) so tailnet peers reach it and nobody else can -- not the
# public IP this used to publish, which the firewall blocks anyway. The tailnet
# IP is assigned at `tailscale up` (boot), so Terraform cannot know it at plan
# time; the `domain-cert` workflow discovers it and upserts the Cloudflare record
# from CI, alongside issuing the cert. Keeping DNS out of Terraform also keeps the
# Cloudflare credential out of the provisioning path entirely.

# ---- Outputs ----------------------------------------------------------------

output "droplet_ipv4" {
  value = digitalocean_droplet.zimmer.ipv4_address
}

output "droplet_name" {
  value = digitalocean_droplet.zimmer.name
}

output "tailscale_hostname" {
  value = local.tailnet_hostname
}
