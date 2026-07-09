# Data stores (deliberately NOT managed by Terraform)

The Zimmer droplet is **cattle**: `Provision production` reaps and re-creates it on
every run, destroying everything on its local disk. So production's database must
live *off* the droplet.

It is a **DigitalOcean Managed Postgres** cluster, referenced from
`infra/terraform/main.tf` as a read-only `data "digitalocean_database_cluster"`.

## Why a data source and not a resource

Two independent reasons, either one sufficient:

1. **Blast radius.** A `resource` gives this automation a destroy path to the one
   irreplaceable thing in the system. A rename, a `count` flip, a `-target` destroy,
   or a lost state file could drop the database. A `data` source has no destroy
   path — Terraform *cannot* delete it, even by accident.
2. **Ephemeral state.** These workflows run with no remote backend, so state starts
   empty each run. Terraform would try to *create* the cluster every time and fail
   with a 409 name conflict.

The cost is that the cluster's own spec is not applied by `terraform apply`. It is
recorded here instead, and the app connects to whatever cluster
`managed_db_cluster_name` names.

**If you later want the cluster managed by Terraform**, you must first adopt a
persistent state backend (DO Spaces via the `s3` backend with `use_lockfile = true`,
requires Terraform >= 1.10), then `terraform import` the cluster. Do not convert this
to a `resource` while state is ephemeral.

## The production cluster

| Setting | Value |
|---|---|
| Name | `zimmer-production-pg` |
| Engine / version | PostgreSQL 16 |
| Size | `db-s-1vcpu-1gb` (~$15/mo) |
| Nodes | 1 |
| Region | `nyc3` (same VPC as the droplet) |
| Tags | `zimmer`, `zimmer-production` |
| Databases | `zimmer_production`, `zimmer_production_cable` |
| User | `doadmin` (the cluster's built-in primary user) |
| Firewall | a single **tag** rule: `zimmer-production` |

### Notes that will bite you if you forget them

- **The firewall is tag-scoped.** Only droplets tagged `zimmer-production` may
  connect. Nothing else on the internet can, including your laptop. To connect
  ad hoc, temporarily add an `ip_addr` rule and remove it afterwards.
- **Both databases must pre-exist.** DO clusters ship only `defaultdb` — there is no
  `postgres` master database, so Rails' `db:prepare` cannot create the app databases
  on a cold cluster. Create them once (`CREATE DATABASE zimmer_production;` and
  `... _cable;`) before the first boot. Thereafter `db:prepare` only migrates.
- **TLS is mandatory.** The app sets `DATABASE_SSLMODE=require`. The compose Postgres
  used by staging speaks no TLS, which is why the default is `prefer`.
- **The app connects over the private VPC host** (`private_host`), so credentials
  never cross the public internet. `private_host` is only routable from inside the
  cluster's VPC, so `main.tf` pins the droplet's `vpc_uuid` to the cluster's
  `private_network_uuid` rather than trusting both to land in the region default.
- The `doadmin` password is stored as the `PROD_DB_PASSWORD` GitHub Actions secret on
  `tadasant-internal`.

## Recreating the cluster from scratch

```bash
doctl databases create zimmer-production-pg \
  --engine pg --version 16 --size db-s-1vcpu-1gb --region nyc3 --num-nodes 1
# then, once online:
doctl databases firewalls append <cluster-id> --rule tag:zimmer-production
# and create the two databases (see "Notes" above)
```

Backups and point-in-time recovery are managed by DigitalOcean and require no
configuration here.
