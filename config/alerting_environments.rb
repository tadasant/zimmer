# frozen_string_literal: true

# The environments that are allowed to send events to GlitchTip — the one list, in
# the one place both halves of the alerting path can read it from.
#
# WHY IT LIVES HERE
# -----------------
# `config/initializers/sentry.rb` needs this list *while the initializer runs*, and
# an initializer cannot reach an autoloaded `app/` constant. Rails sets up the main
# Zeitwerk autoloader in `Rails::Application::Finisher`'s `:setup_main_autoloader`
# initializer, which runs AFTER the engine's `:load_config_initializers` has loaded
# every file in `config/initializers/`. So a reference to an `app/` constant from an
# initializer body raises `NameError: uninitialized constant` — not sometimes, always.
#
# That is not theoretical either. [#1121](https://github.com/tadasant/zimmer/pull/1121)
# shipped the list as `ErrorReporter::ALERTING_ENVIRONMENTS` in
# `app/services/error_reporter.rb` and broke every production deploy: the image
# entrypoint's `bin/rails db:prepare` aborted, the container never became healthy, and
# Kamal rolled back. `development` and `test` saw
# none of it, because the whole `Sentry.init` block is gated on `SENTRY_DSN_BACKEND` and
# those environments do not set it.
#
# `config/application.rb` `require_relative`s this file, exactly as it does
# `connection_budget.rb` and `cron_schedule.rb`, so the constant exists before the first
# initializer runs and stays reachable from every later phase (`after_initialize`,
# `to_prepare`, request time). Do not move it back under `app/`.
#
# WHAT IT PROTECTS
# ----------------
# Zimmer runs its agent sessions inside the production container, whose environment
# carries production's `SENTRY_DSN_BACKEND`. `CliSpawnEnv` strips it from agent-session
# child processes, but anything that still sees the container's environment — and a
# `RAILS_ENV=test bin/rails` in an agent's clone once did — would initialize the SDK
# against the production DSN. Gating on the DSN's presence cannot stop that, because the
# DSN really is there. This allowlist is what holds, because it holds even when the
# production DSN genuinely is present ([#176](https://github.com/tadasant/zimmer/issues/176)).
module AlertingEnvironments
  # Frozen so nothing can widen it at runtime.
  ALL = %w[production staging].freeze
end
