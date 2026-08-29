require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Catalog source. `AIR_CONFIG` lets an operator point this instance at their OWN
  # AIR catalog -- e.g. a private catalog delivered onto the box and mounted at
  # /rails/catalog (see docs: self-hosting / custom catalog). When unset, or set but
  # not yet present on disk, it falls back to the self-contained catalog baked into
  # the image (`air.production.json`).
  #
  # The "set but missing" fallback matters during bootstrap: on a fresh box the
  # mounted catalog volume may be empty until the catalog is delivered, and
  # AirCatalogService resolves a non-existent air_json_path to an EMPTY catalog (zero
  # roots). Falling back to the in-image catalog keeps the app usable until the real
  # one lands; once it does and the app restarts, AIR_CONFIG wins.
  config.air_json_path =
    if (configured = ENV["AIR_CONFIG"]).present? && File.exist?(configured)
      configured
    else
      Rails.root.join("air.production.json").to_s
    end

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # These headers cover public/ — 404.html, manifest.json, service-worker.js, the
  # icons — and NOT the digest-stamped build output, which Propshaft serves under
  # /assets with its own far-future headers. Nothing in public/ is digest stamped,
  # so a far-future max-age here pins a stale copy of a file whose URL never
  # changes: replacing an icon or editing the manifest would not reach anyone who
  # had already loaded the old one. An hour is long enough to matter and short
  # enough that a redeploy is visible the same day.
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

  # GoodJob configuration for production
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
  #     resolves its attempts). The `triggers` argument with a human added: someone
  #     is watching the /quotas login panel spin while this runs, and on `default`
  #     it queued behind whatever periodic or multi-minute job held those four
  #     threads -- including, since RuntimeLoginJob pins a thread for up to twelve
  #     minutes, an earlier login. Periodic auth work (RefreshRuntimeAuthTokensJob,
  #     RefreshMcpOauthTokensJob) deliberately stays on `default`: nobody is waiting
  #     on it, and it is exactly the bulk character this lane exists to escape.
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
  # The schedule itself lives in config/cron_schedule.rb, once, for all three
  # environments -- see the header there for why. Each entry names the environments it
  # runs in, so a job production runs and staging does not is a written statement
  # rather than a line missing from a file nobody diffs.
  config.good_job.cron = CronSchedule.for(:production)

  # Redis cache store for production
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
  # deploy-provisioned APP_HOST (set in config/deploy.production.yml) so mailer
  # links resolve to the real deployment host; the placeholder fallback only
  # applies when a self-hosted deploy has not set APP_HOST.
  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST") { "example.com" } }

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

  # Only use :id for inspections in production.
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
