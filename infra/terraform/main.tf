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
  default     = false
  description = <<-EOT
    Whether to create a dedicated DigitalOcean Project for this environment.

    Still OFF by default, even with persistent state. Remote state fixes the case
    where Terraform created the project itself -- but a project that ALREADY exists
    and is not in state still 409s ("name is already in use"), because DO project
    names are account-unique. Both environments have one from the pre-Kamal era, so
    turning this on requires a one-time `terraform import` of the existing project
    first. A DO Project is purely organizational (a folder in the console), so that
    is not worth the extra failure mode in the provisioning path; the droplet works
    fine in the account's default project.
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

variable "admin_ssh_pubkeys" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Admin SSH public keys authorized for root, on top of the Kamal deploy key -- how a
    cloud-init-provisioned droplet learns an operator/tooling key (e.g. the key an
    SSH-based MCP server connects with).

    Set it per environment in *.tfvars -- NOT as a default here, so a fork does not
    silently authorize someone else's key on its own box. The lists are per environment
    on purpose and are NOT meant to be identical: the key Zimmer's own agent sessions
    hold is authorized on staging and deliberately withheld from production, because
    those sessions RUN ON production and this variable authorizes root. See
    docs/operate/ssh-access.md#who-is-authorized-where before reconciling them.

    Deliberately NOT var.ssh_key_fingerprints (DigitalOcean-registered keys): that
    argument is ForceNew on digitalocean_droplet, so adding a key there would make
    the deploy workflow's `terraform apply -auto-approve` DESTROY and recreate the
    droplet -- skipping the tailnet-node reap that only runs behind recreate_droplet,
    which lands the replacement on the tailnet as zimmer-<env>-1 and breaks the
    hostname the deploy resolves. cloud-init has no such trap: user_data is under
    `ignore_changes`, so a key added here reaches the box on the next rebuild and
    never force-replaces one.
  EOT
}

variable "ssh_host_ed25519_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    Optional pinned SSH host private key (ed25519). When set, cloud-init installs it
    so the droplet keeps a STABLE host identity across rebuilds -- which is what keeps
    known_hosts valid for the clients that reach production over :2222 (a human, and
    the off-box orchestrator's SSH MCP server) instead of tripping a host-key-changed
    error on every re-provision. NOT for a Zimmer agent session: those run ON this box
    and are deliberately not authorized on it (docs/operate/ssh-access.md).
    Empty (staging) = a fresh host key each boot, which is fine for a disposable box.
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

variable "app_required_backends" {
  type        = number
  default     = 91
  description = <<-EOT
    Client backends the database must be able to serve for a deploy of this app to be
    safe. It is NOT a free parameter: it is what `ConnectionBudget.required_backends`
    (config/connection_budget.rb) derives from Puma's threads, GoodJob's scheduler
    threads, the cable pools, and a x2 allowance for the window in which Kamal runs the
    old and new containers side by side. test/config/connection_budget_test.rb asserts
    this default still equals that derivation, so the two cannot drift.

    Change the app's DEFAULTS (config/connection_budget.rb) and this number moves with
    them, because the test forces it to. The postcondition below then refuses to plan
    against a cluster whose PLAN cannot serve it -- the failure the app itself cannot
    detect, since an ActiveRecord pool is a promise, and a lazy one: an overcommitted app
    looks healthy until traffic calls the promise in.

    KNOW THE GAP: Terraform sees the repo, not the container. Raising a thread count
    through the ENVIRONMENT instead (GOOD_JOB_AGENTS_THREADS, DB_POOL, ... in
    config/deploy.*.yml) moves the app's real promise while this default -- and therefore
    this check -- keeps validating the old one. Nothing here sets those today. The runtime
    check that DOES see them is `bin/rails db:connection_budget`, which reads the actual
    process env and the actual server.
  EOT
}

# ---- Managed database (read-only reference) ----------------------------------
#
# A DATA SOURCE, on purpose: it has no destroy path, so Terraform can never delete,
# replace, or resize the one irreplaceable resource in the system. Staging never uses a
# managed cluster (it runs a throwaway Postgres accessory on the droplet), so nothing
# here applies to it.
#
# The trade-off is that Terraform cannot RESIZE the cluster either -- so it does the
# next best thing and refuses to proceed against one that is too small. The plan slug
# fixes the connection ceiling (DigitalOcean allots 25 connections per GiB of RAM and
# reserves 3), and a cluster whose ceiling is under the app's budget cannot serve the
# app: the pools are promises Postgres will decline, as FATAL "remaining connection
# slots are reserved for roles with the SUPERUSER attribute" -- an HTTP 500, not a
# queue. Resizing is an in-place operator action (`doctl databases resize`); this
# postcondition is what makes skipping it impossible to miss.
data "digitalocean_database_cluster" "pg" {
  count = var.managed_db_cluster_name == "" ? 0 : 1
  name  = var.managed_db_cluster_name

  lifecycle {
    postcondition {
      condition = lookup(local.do_pg_usable_backends, self.size, 0) >= var.app_required_backends
      error_message = join("", [
        "Managed Postgres cluster '${var.managed_db_cluster_name}' is on plan '${self.size}', which serves ",
        "${lookup(local.do_pg_usable_backends, self.size, 0)} client backends. Zimmer commits to ",
        "${var.app_required_backends} (see config/connection_budget.rb). Resize the cluster to a plan that ",
        "covers the budget -- `doctl databases resize <cluster-id> --size db-s-2vcpu-4gb --num-nodes 1` -- or ",
        "lower the app's thread counts (GOOD_JOB_AGENTS_THREADS is the big one) and app_required_backends with ",
        "it. If the plan slug is simply missing from local.do_pg_usable_backends, add it there.",
      ])
    }
  }
}

# ---- Locals -----------------------------------------------------------------

locals {
  # Client backends each DigitalOcean Managed Postgres plan can serve: DO allots 25
  # connections per GiB of RAM and reserves 3 for its own superuser maintenance, so the
  # app only ever sees (25 * GiB) - 3. The ceiling is a property of the PLAN -- it is
  # not in DO's tunable Postgres config surface, and it is not something a connection
  # pool can conjure (a DO PgBouncer pool's backends are allotted OUT of this same
  # number). Growing it means changing the plan.
  # https://docs.digitalocean.com/products/databases/postgresql/details/limits/
  do_pg_usable_backends = {
    "db-s-1vcpu-1gb"   = 22
    "db-s-1vcpu-2gb"   = 47
    "db-s-2vcpu-4gb"   = 97
    "db-s-4vcpu-8gb"   = 197
    "db-s-6vcpu-16gb"  = 397
    "db-s-8vcpu-32gb"  = 797
    "db-s-16vcpu-64gb" = 997 # DO caps the limit at 997 on the largest plans
  }

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
    #
    # The trade-off: because the Kamal deploy key and the Caddyfile are delivered
    # ONLY through user_data, rotating KAMAL_SSH_KEY or changing `domain` produces no
    # plan diff and will not reach the box. Both require an explicit
    # `terraform taint digitalocean_droplet.zimmer`. See docs limitations.
    ignore_changes = [user_data]

    # NOTE: deliberately NOT create_before_destroy. The tailnet hostname is fixed
    # (zimmer-${var.environment}), so standing a replacement up alongside the old box
    # would briefly put TWO online peers on the tailnet with the same MagicDNS name --
    # and the deploy workflow resolves its target by that name. It could then deploy
    # onto the droplet Terraform is about to destroy. A replacement is rare by design
    # here, so a short gap is the safer trade.

    # Fail fast at plan time rather than booting a droplet Kamal cannot reach and
    # only discovering it as an SSH failure minutes later.
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
    admin_ssh_pubkeys        = var.admin_ssh_pubkeys
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

# Firewall: ZERO public TCP ingress. The only inbound rule is Tailscale's UDP, so
# every way into this box -- app, SSH, break-glass -- rides the tailnet.
#
# SSH IS TAILNET-ONLY. There is no `22` rule here, on purpose, and there must not be:
#
#   tailnet :22    Tailscale SSH (cloud-init's `tailscale up --ssh`). Authenticates by
#                  tailnet identity, ignores publickey entirely. This is the channel
#                  Kamal actually deploys over.
#   tailnet :2222  Real OpenSSH, for plain publickey clients that cannot speak
#                  Tailscale SSH (the ssh-agent-mcp-server MCP). Bound by the
#                  ssh.socket drop-in cloud-init installs.
#
# A DigitalOcean cloud firewall filters the PUBLIC interface only -- it does not
# filter tailscale0 -- so tailnet peers reach both ports while the internet reaches
# neither, with no rule required for either.
#
# DO NOT re-add a `22` inbound rule to "get access back". It used to be open to
# 0.0.0.0/0 against an sshd that (first-match on 50-cloud-init.conf) accepted ROOT
# PASSWORD auth, and both droplets were being brute-force flooded: production logged
# 1023 pre-auth failures in 2000 lines of journal, and staging's pre-auth queue was
# saturated to the point that `Exceeded MaxStartups` reset every connection -- SSH was
# effectively DOWN. Break-glass without a rule: `tailscale ssh root@zimmer-<env>`, or
# the DigitalOcean web console.
resource "digitalocean_firewall" "zimmer" {
  name        = "zimmer-${var.environment}"
  droplet_ids = [digitalocean_droplet.zimmer.id]

  # Tailscale coordination / direct connections. The ONLY public ingress.
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

# The connection headroom the app is running on, so it is visible in `terraform output`
# rather than something you rediscover from a 500. Null on staging (no managed cluster;
# its Postgres accessory runs at the postgres:16 default of max_connections=100, which
# leaves the same 97 usable backends as the db-s-2vcpu-4gb plan).
output "managed_db_usable_backends" {
  value = local.use_managed_db ? lookup(local.do_pg_usable_backends, data.digitalocean_database_cluster.pg[0].size, 0) : null
}

output "app_required_backends" {
  value = var.app_required_backends
}
