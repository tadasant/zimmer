# frozen_string_literal: true

# Background job to install bundle dependencies for a session's working directory.
# This runs asynchronously so that Claude Code can start immediately without waiting
# for gem installation to complete.
#
# In most cases, Claude Code starts by reading files and exploring the codebase,
# which doesn't require gems. By the time it needs to run Rails commands,
# bundle install has usually completed.
class BundleInstallJob < ApplicationJob
  include DatabaseRetry

  queue_as :default

  # Don't retry - if it fails, Rails commands just won't work
  # The user can manually run bundle install if needed
  discard_on StandardError

  # GoodJob::InterruptError < StandardError, so the broad discard_on above would otherwise
  # catch deploy interrupts and log them at ERROR (tripping the "any Zimmer ERROR → critical"
  # Grafana alert). Re-register the quiet INFO handler AFTER discard_on so last-registered-wins
  # routes interrupts there instead. See ApplicationJob.discard_interrupt_quietly.
  discard_interrupt_quietly

  # @param session_id [Integer] The session ID (for logging context)
  # @param working_directory [String] The directory containing the Gemfile
  def perform(session_id, working_directory)
    session = Session.find_by(id: session_id)
    return unless session

    # Skip if session is no longer active (archived, failed)
    # The clone directory may be deleted or in the process of being cleaned up
    return if session.archived? || session.failed?

    gemfile_path = File.join(working_directory, "Gemfile")
    return unless File.exist?(gemfile_path)

    # Clear bundler-related environment variables to avoid inheriting container's bundle config
    bundle_config_dir = File.join(working_directory, ".bundle")
    clean_env = build_clean_bundler_env(bundle_config_dir)

    # Configure bundler for this specific clone (best-effort, failures are acceptable)
    configure_bundler(clean_env, working_directory)

    # Run bundle install
    _stdout, stderr, status = Open3.capture3(
      clean_env,
      "bundle", "install",
      "--jobs", "4",
      "--retry", "3",
      chdir: working_directory
    )

    if status.success?
      with_db_retry do
        session.logs.create!(
          content: "Background bundle install completed successfully",
          level: "info"
        )
      end
    else
      with_db_retry do
        session.logs.create!(
          content: "Background bundle install failed: #{stderr.lines.first(3).join.truncate(200)}",
          level: "warning"
        )
      end
    end
  end

  private

  def build_clean_bundler_env(bundle_config_dir)
    clean_env = ENV.to_h.dup
    ENV.each_key do |k|
      clean_env[k] = nil if k.start_with?("BUNDLE") || k == "RUBYOPT"
    end
    clean_env["BUNDLE_APP_CONFIG"] = bundle_config_dir
    clean_env
  end

  def configure_bundler(clean_env, working_directory)
    # Set local path for gems
    # Note: Config failures are ignored because this is a best-effort background task.
    # If config fails, bundle install will still run with default settings.
    Open3.capture3(
      clean_env,
      "bundle", "config", "set", "--local", "path", "vendor/bundle",
      chdir: working_directory
    )

    # Disable deployment mode
    Open3.capture3(
      clean_env,
      "bundle", "config", "set", "--local", "deployment", "false",
      chdir: working_directory
    )
  end
end
