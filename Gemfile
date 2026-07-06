source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# Use PostgreSQL as the database for Active Record
gem "pg", "~> 1.6"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Background job processing with GoodJob (Postgres-based)
gem "good_job"

# Redis for caching
gem "redis"

# Error tracking via the self-hosted GlitchTip instance
# (https://glitchtip.obs.example.com). GlitchTip is Sentry-API compatible, so
# the official sentry-ruby/sentry-rails SDKs work as-is. Pinned to match the
# pulsemcp web-app for consistency. Configured in config/initializers/sentry.rb
# and a hard no-op unless SENTRY_DSN_BACKEND is set (so dev stays quiet).
gem "sentry-ruby", "6.6.2"
gem "sentry-rails", "6.6.2"

# Pin connection_pool to avoid breaking change in 3.0 that's incompatible with Rails 8.x redis_cache_store
# See: https://github.com/rails/rails/issues/56461
gem "connection_pool", "< 4.0"

# Use the database-backed adapter for Action Cable
gem "solid_cable"

# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"

# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"

# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"

# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

# Administrate for database admin UI (renamed to supervisor)
gem "administrate"

# Markdown rendering for conversation transcripts
gem "redcarpet"

# Syntax highlighting for code blocks
gem "rouge", "~> 5.0"

# Anthropic API client for title generation
gem "anthropic", "~> 1.55"

# State machine for session lifecycle management
gem "aasm"

# Pagination
gem "kaminari"

# Web Push notifications (VAPID key generation and push delivery)
# Using web-push gem (pushpad fork) which supports OpenSSL 3.0+
gem "web-push", "~> 3.1"

# Slack API client for Triggers feature
gem "slack-ruby-client"

# ZIP file creation for transcript archive exports
gem "rubyzip"

# TOML parsing + serialization for the Codex runtime's .codex/config.toml,
# which CodexConfigTomlPostProcessor reads and rewrites after `air prepare`.
gem "toml-rb"

# Zstandard decompression for OpenAI Codex rollout transcripts
# (newer Codex CLI versions write ~/.codex/sessions/.../rollout-*.jsonl.zst)
gem "zstd-ruby"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # System testing gems
  gem "capybara"
  gem "selenium-webdriver"

  # Mocking library for tests
  gem "mocha"

  # minitest/mock extracted to separate gem in minitest 6.0
  gem "minitest-mock"
end
