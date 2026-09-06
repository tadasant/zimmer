require "active_support/core_ext/integer/time"
require_relative "../../app/services/air_catalog_ref_rewriter"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Staging shares production's catalog source: the in-image air.production.json,
  # which points at the six artifact indexes baked into the image
  # (`./skills/skills.json` and its siblings, copied to the image root alongside it)
  # and resolves entirely from local paths, offline. It is content-identical to the
  # dev/test air.json today; the split is a seam, so the image can change its own
  # catalog sources without touching dev. AIR_CONFIG env still wins.
  #
  # AIR_CATALOG_REF (optional): pins every `github://tadasant/zimmer-catalog/...`
  # URI in the catalog to one ref (branch / tag / commit SHA), so a staging deploy
  # can test catalog changes from a feature branch without merging them to main.
  # The rewritten copy is written to tmp/ and resolved from there.
  #
  # Its reach is narrower than it looks, in two ways that are easy to misread:
  #
  #   1. It applies to the in-image air.production.json ONLY. It sits inside the
  #      ENV.fetch("AIR_CONFIG") block, so a deployment that sets AIR_CONFIG —
  #      which is how an operator mounts their own catalog, and what
  #      config/deploy.production.yml does — bypasses it entirely.
  #   2. air.production.json declares no github:// URIs, so there is nothing in it
  #      for the rewrite to match.
  #
  # Together those mean the knob pins nothing on any deployment as configured
  # today, which is why an unmatched rewrite says so and falls back to the base
  # config. Falling back is not cosmetic: the rewritten copy lands in tmp/, and
  # air.production.json's index paths are RELATIVE to the config file's directory
  # (`./skills/skills.json`), so resolving the copy from tmp/ would look for
  # tmp/skills/skills.json and find nothing. Returning base_path when the rewrite
  # matched nothing keeps a set-but-inert AIR_CATALOG_REF from emptying the
  # catalog. See docs/limitations.md for the same trap on the CatalogPin path.
  config.air_json_path = ENV.fetch("AIR_CONFIG") {
    base_path = Rails.root.join("air.production.json").to_s
    catalog_ref = ENV["AIR_CATALOG_REF"].to_s.strip
    if catalog_ref.empty?
      base_path
    else
      source = File.read(base_path)
      rewritten = AirCatalogRefRewriter.rewrite(
        source,
        pins: { AirCatalogRefRewriter::CATALOG_PREFIX => catalog_ref }
      )
      # Compare parsed documents: `rewrite` re-serializes with JSON.pretty_generate
      # whether or not it matched anything, so the source text is never the baseline.
      if JSON.parse(rewritten) == JSON.parse(source)
        # Kernel#warn, not Rails.logger: config.logger is assigned further down this
        # same block, so there is no configured logger yet. Fires once per process
        # (each Puma worker, each GoodJob worker).
        warn "[staging] AIR_CATALOG_REF=#{catalog_ref} changed nothing in #{base_path} " \
             "(no #{AirCatalogRefRewriter::CATALOG_PREFIX} URI needed pinning). " \
             "Resolving the catalog unrewritten."
        base_path
      else
        out_path = Rails.root.join("tmp", "air.staging.json")
        FileUtils.mkdir_p(out_path.dirname)
        File.write(out_path, rewritten)
        out_path.to_s
      end
    end
  }

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Matches production: these headers cover public/, which is not digest stamped,
  # so a far-future max-age would pin a stale icon or manifest at a URL that never
  # changes. Propshaft serves the digested build output under /assets separately.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.hour.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # SSL can be disabled for staging environments without HTTPS
  unless ENV["DISABLE_SSL"] == "true"
    config.assume_ssl = true

    # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
    config.force_ssl = true
  end

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # GoodJob configuration for staging
  # Use :external mode - requires separate worker process
  config.good_job.execution_mode = ConnectionBudget.execution_mode

  # Queue configuration with thread allocation (configurable via ENV):
  # - agents: Long-running AgentSessionJob instances
  # - pollers: Singleton polling jobs that shouldn't queue up
  # - triggers: Latency-sensitive trigger firing (AoEventTriggerJob,
  #     ScheduleTriggerJob). Isolated onto its own scheduler so state-change and
  #     scheduled wakes are never starved behind the `default` queue's periodic/
  #     bulk backlog (heartbeat sweeps, Slack polling, cleanup, etc.).
  # - auth: User-interactive authentication (RuntimeLoginJob and the reaper that
  #     resolves its attempts), kept off `default` so a human watching the /inference
  #     login panel never waits behind a periodic sweep. See production.rb.
  # - default: Everything else - cleanup, title generation, etc.
  #
  # Every scheduler thread here can be executing a job, and an executing GoodJob job
  # holds a database connection for its whole duration (its advisory lock is
  # session-scoped). So these counts ARE the worker's connection demand, and they come
  # from ConnectionBudget -- the same derivation that sizes the pool in database.yml
  # and the server-side budget Terraform enforces. Raise a queue's ENV knob and the
  # pool that has to serve it moves with it.
  config.good_job.queues = ConnectionBudget.good_job_queues
  config.good_job.max_threads = ConnectionBudget.good_job_max_threads
  config.good_job.enable_cron = true
  config.good_job.enable_dashboard = true
  # Resolved from config/cron_schedule.rb, the single source for all three environments.
  # Anything production schedules and staging does not is declared there, on the entry.
  config.good_job.cron = CronSchedule.for(:staging)

  # Redis cache store for staging
  config.cache_store = :redis_cache_store, {
    url: "#{ENV["REDIS_URL"]}/0",
    connect_timeout: 30,
    read_timeout: 5,
    write_timeout: 15,
    reconnect_attempts: 3,
    error_handler: ->(method:, returning:, exception:) {
      Rails.logger.error("[redis_cache_store] Redis error: #{exception.class} - #{exception.message}")
    },
    pool: {
      size: ENV.fetch("REDIS_POOL_SIZE", 50).to_i,
      timeout: 30
    }
  }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates. Reads the
  # deploy-provisioned APP_HOST (set in config/deploy.staging.yml) so mailer
  # links resolve to the real deployment host; the placeholder fallback only
  # applies when a self-hosted deploy has not set APP_HOST.
  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST") { "staging.zimmer.example.com" } }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in staging/production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
