require_relative "boot"

require "rails/all"

require "good_job/engine"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Zimmer
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Zimmer Extensions (see app/services/ao/extension.rb) live one directory each
    # under app/extensions/<id>/ so an extension is a single self-contained,
    # deletable unit. Collapse those per-extension directories so Zeitwerk does
    # NOT turn the directory name into a namespace: app/extensions/pty_transport/
    # pty_claude_cli_adapter.rb maps to PtyClaudeCliAdapter, not
    # PtyTransport::PtyClaudeCliAdapter. This lets an extension be removed
    # wholesale for the OSS build without renaming any of its constants.
    Rails.autoloaders.main.collapse(Rails.root.join("app/extensions/*"))

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Execution layer configuration
    # Configure the directory for bare git repositories.
    config.x.execution.repos_dir = ENV.fetch("EXECUTION_REPOS_DIR", "/tmp/agents/repos")
    # NOTE: the clones base directory is intentionally NOT configured here. It is
    # resolved at runtime through ClonesDirectory.base (env: AGENT_CLONES_DIR),
    # which is the single source of truth shared by every clone writer
    # (GitCloneService, ForkSessionService, the LocalFilesystem execution provider)
    # and the garbage collector (StaleCloneCleanupJob, OrphanCloneFilesystemCleanupJob).
    # Clones live on durable storage that survives container restarts AND deploys
    # (the agent-orchestrator_agent-clones named volume; see config/deploy.production.yml).

    # Path to the air.json that drives catalog discovery (skills, mcp servers,
    # agent roots, references, hooks, plugins). Defaults to ~/.air/air.json which
    # matches the AIR CLI default. Override with AIR_CONFIG env var, or in a
    # specific environment via config/environments/*.rb.
    config.air_json_path = ENV.fetch("AIR_CONFIG") { File.expand_path("~/.air/air.json") }

    # This is a full web application with views, not API-only
    config.api_only = false

    # Use GoodJob as the Active Job queue adapter
    config.active_job.queue_adapter = :good_job
  end
end
