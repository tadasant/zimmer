# Zimmer infrastructure on DigitalOcean.
#
# ONE PERSISTENT droplet per environment, joined to a Tailscale tailnet so the app
# is reachable ONLY over the VPN. The droplet is a bootstrap-only host: Terraform
# provisions it (Docker + Tailscale + a deploy key) and then leaves it alone --
# Kamal (config/deploy.*.yml) owns the app stack and swaps containers on it with
# zero downtime. The same module serves staging and production; the difference is
# entirely in *.tfvars.
#
# WHY THE DROPLET NO LONGER CHURNS
# --------------------------------
# The app image, env, and data stores used to be baked into user_data, so every
# app change re-rendered cloud-init and force-REPLACED the droplet. They now live
# in Kamal, and `lifecycle { ignore_changes = [user_data] }` (below) means a
# bootstrap-template edit never replaces the box either. Combined with a remote
# state backend, `terraform apply` reconciles a long-lived droplet instead of the
# old reap-and-recreate-every-run dance.
#
# Nothing secret lives in this file. Secrets (DO token, Tailscale auth key, the
# deploy SSH key) are passed as TF variables, which in CI come from GitHub Actions
# secrets and locally from your shell (TF_VAR_*).

terraform {
  required_version = ">= 1.10.0" # S3-native state locking (use_lockfile) for DO Spaces
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.43"
    }
  }
  # Remote state on DigitalOcean Spaces (S3-compatible). Configured per environment
  # via `-backend-config` at `terraform init` (bucket/key/endpoints/region + the
  # Spaces access keys) so this block stays identical across the staging and the
  # mirrored production copy. A persistent backend is what lets apply reconcile the
  # existing droplet instead of 409-colliding on account-unique names.
  backend "s3" {}
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

variable "manage_project" {
  type        = bool
  default     = true
  description = <<-EOT
    Whether to create a dedicated DigitalOcean Project for this environment. On by
    default now that state is persistent: a DO Project name is account-unique, and
    with a remote backend Terraform reconciles the existing project instead of
    409-colliding the way it did under the old ephemeral tfstate.
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

variable "deploy_ssh_pubkey" {
  type        = string
  description = <<-EOT
    Public half of the Kamal deploy keypair (KAMAL_SSH_KEY). cloud-init authorizes
    it for root so Kamal can SSH in over the tailnet to run docker / kamal-proxy.
    The private half is a GH Actions secret used only by the deploy workflow.
  EOT
}

variable "ssh_host_ed25519_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    Optional pinned SSH host private key (ed25519). When set, cloud-init installs it
    so the droplet keeps a STABLE host identity across rebuilds -- which is what
    keeps the ssh-tadasant-zimmer-prod MCP's known-hosts valid instead of tripping a
    host-key-changed error on every re-provision. Empty (staging) = a fresh host key
    each boot, which is fine for a disposable box.
  EOT
}

variable "ssh_host_ed25519_key_pub" {
  type        = string
  default     = ""
  description = "Public half of ssh_host_ed25519_key. Required when that is set."
}

variable "domain" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional FQDN for custom-domain HTTPS over the tailnet (staging.zimmer.tadasant.com
    / zimmer.tadasant.com). When set, cloud-init runs a Caddy TLS terminator on :443
    that reverse-proxies to kamal-proxy on :80.

    Caddy does NOT obtain its own certificate and the droplet holds NO DNS credential:
    the `domain-cert` workflow issues the cert out-of-band (ACME DNS-01, Cloudflare
    token confined to CI), registers the `domain -> tailnet IP` A record, and pushes
    only the cert onto the box. This variable just turns the terminator on. Empty =
    plain HTTP over the tailnet only.
  EOT
}

# ---- Managed database variables ----------------------------------------------

variable "managed_db_cluster_name" {
  type        = string
  default     = ""
  description = <<-EOT
    Name of an EXISTING DigitalOcean Managed Postgres cluster to use. Empty (the
    default, used by staging) means the Kamal stack runs its own throwaway Postgres
    accessory on the droplet. Set this in production so the database survives the
    droplet being rebuilt; its connection details are exposed as outputs for the
    production Kamal deploy to wire into DATABASE_HOST.
  EOT
}

# ---- Managed database (read-only reference) ----------------------------------
#
# Still a DATA SOURCE in this phase. Promoting it to a managed resource (with
# prevent_destroy + a one-time `terraform import`) is a production-only change that
# lands with the prod cutover; staging never uses a managed cluster, so nothing
# here depends on it. A data source has no destroy path, so Terraform can never
# delete, replace, or resize the one irreplaceable resource in the system.
data "digitalocean_database_cluster" "pg" {
  count = var.managed_db_cluster_name == "" ? 0 : 1
  name  = var.managed_db_cluster_name
}

# ---- Locals -----------------------------------------------------------------

locals {
  # The tailnet MagicDNS name you browse to. Production is simply `zimmer`
  # (http://zimmer); every other environment is suffixed (http://zimmer-staging).
  tailnet_hostname = var.environment == "production" ? "zimmer" : "zimmer-${var.environment}"

  # When a managed cluster is named (production), the droplet is pinned into its VPC
  # so the private DB host is routable, and the connection details flow to Kamal via
  # outputs. Otherwise (staging) the Kamal stack runs its own Postgres accessory.
  use_managed_db = var.managed_db_cluster_name != ""
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

  # Pin the droplet into the managed cluster's VPC (production) so its private_host
  # is routable; null (staging) lets DigitalOcean pick the region default.
  vpc_uuid = local.use_managed_db ? data.digitalocean_database_cluster.pg[0].private_network_uuid : null

  lifecycle {
    # The bootstrap template renders once. Ignore user_data drift so a change to it
    # (or to anything Kamal now owns) never force-replaces this persistent host --
    # this is the setting that kills the recreate-on-every-change churn.
    ignore_changes = [user_data]

    # When the droplet genuinely must be replaced (size/region/image), stand up the
    # new one before destroying the old so the reserved IP + tailnet name hand over
    # cleanly.
    create_before_destroy = true

    # Fail fast at plan time instead of booting a droplet that can't authenticate to
    # the managed DB and only surfacing as a health-check timeout ~10 minutes later.
    precondition {
      condition     = var.deploy_ssh_pubkey != ""
      error_message = "deploy_ssh_pubkey must be set (the public half of KAMAL_SSH_KEY) so Kamal can reach the droplet."
    }
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    environment              = var.environment
    tailnet_hostname         = local.tailnet_hostname
    tailscale_auth_key       = var.tailscale_auth_key
    deploy_ssh_pubkey        = var.deploy_ssh_pubkey
    ssh_host_ed25519_key     = var.ssh_host_ed25519_key
    ssh_host_ed25519_key_pub = var.ssh_host_ed25519_key_pub
    domain                   = var.domain
  })
}

# Stable public IP that survives a droplet rebuild (create_before_destroy hands it
# over), so DNS / any public-IP-keyed access does not churn on re-provision.
resource "digitalocean_reserved_ip" "zimmer" {
  region     = var.region
  droplet_id = digitalocean_droplet.zimmer.id
}

# Firewall: NO public app ingress. Only SSH (Kamal's control channel + break-glass)
# and Tailscale's UDP. All app traffic rides the tailnet.
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

# No DNS record here. A custom domain's A record points at the droplet's TAILNET IP
# (100.x), assigned at `tailscale up` (boot) and therefore unknown at plan time; the
# `domain-cert` workflow discovers it and upserts the Cloudflare record from CI,
# alongside issuing the cert. Keeping DNS out of Terraform also keeps the Cloudflare
# credential out of the provisioning path.

# ---- Outputs ----------------------------------------------------------------

output "droplet_ipv4" {
  value = digitalocean_droplet.zimmer.ipv4_address
}

output "reserved_ipv4" {
  value = digitalocean_reserved_ip.zimmer.ip_address
}

output "droplet_name" {
  value = digitalocean_droplet.zimmer.name
}

output "tailscale_hostname" {
  value = local.tailnet_hostname
}

# Managed DB connection details for the production Kamal deploy to wire into
# DATABASE_HOST/PORT. Null on staging (which runs its own Postgres accessory).
output "managed_db_host" {
  value = local.use_managed_db ? data.digitalocean_database_cluster.pg[0].private_host : null
}

output "managed_db_port" {
  value = local.use_managed_db ? data.digitalocean_database_cluster.pg[0].port : null
}
