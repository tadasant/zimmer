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
  description = "Optional FQDN to create an A record for (e.g. staging.zimmer.tadasant.com). Empty = no DNS."
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

# ---- Resources --------------------------------------------------------------

resource "digitalocean_project" "zimmer" {
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

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    environment        = var.environment
    image_ref          = var.image_ref
    tailscale_auth_key = var.tailscale_auth_key
    ghcr_username      = var.ghcr_username
    ghcr_token         = var.ghcr_token
    secret_key_base    = var.secret_key_base
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

# Optional public DNS A record. The app is Tailscale-only, so this is mainly a
# convenience pointer; it resolves to the droplet's public IP but the app port
# is not publicly reachable.
resource "digitalocean_record" "zimmer" {
  count  = var.domain == "" ? 0 : 1
  domain = join(".", slice(split(".", var.domain), 1, length(split(".", var.domain))))
  type   = "A"
  name   = split(".", var.domain)[0]
  value  = digitalocean_droplet.zimmer.ipv4_address
  ttl    = 300
}

# ---- Outputs ----------------------------------------------------------------

output "droplet_ipv4" {
  value = digitalocean_droplet.zimmer.ipv4_address
}

output "droplet_name" {
  value = digitalocean_droplet.zimmer.name
}

output "tailscale_hostname" {
  value = "zimmer-${var.environment}"
}
