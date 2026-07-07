class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # Retry on database timeout errors - these are transient and should resolve
  # Wait progressively longer between retries: 5s, 10s, 20s, 40s, 80s (max 5 attempts)
  retry_on ActiveRecord::StatementTimeout, wait: :exponentially_longer, attempts: 5

  # Include GoodJob interrupt handling for graceful shutdown
  include GoodJob::ActiveJobExtensions::InterruptErrors

  # Include GoodJob concurrency control for singleton/throttling patterns
  # This enables good_job_control_concurrency_with in subclasses
  include GoodJob::ActiveJobExtensions::Concurrency

  # Quietly discard a GoodJob interrupt (deploy / graceful shutdown) — log it at INFO
  # rather than ERROR. Interruptions happen on every deploy and are EXPECTED operational
  # behavior, not errors. Deploy-orphaned sessions/jobs are recovered separately
  # (CleanupOrphanedSessionsJob / DeploymentRecoveryJob), so discarding here — with no
  # retry — is correct.
  #
  # We deliberately use rescue_from rather than `discard_on GoodJob::InterruptError`.
  # On Rails 8.1, discard_on ALWAYS fires the `discard.active_job` notification — even when
  # given a block — and ActiveJob::LogSubscriber#discard logs that event at ERROR
  # (`subscribe_log_level :discard, :error`). That single ERROR line ("Discarded <Job>
  # (Job ID: …) due to a GoodJob::InterruptError (…).") trips the "any Zimmer ERROR → critical"
  # Grafana rule on every deploy that interrupts a running job — a false alert with no user
  # impact. A discard_on block does NOT replace that LogSubscriber on Rails 8.1; it runs in
  # addition to it. rescue_from swallows the error (so the job is discarded and NOT retried,
  # exactly like discard_on) WITHOUT emitting the discard notification, letting us log the
  # interruption at INFO instead.
  #
  # IMPORTANT — subclasses with a broad `discard_on StandardError` MUST call this macro
  # AGAIN after that declaration. GoodJob::InterruptError < StandardError, and ActiveSupport
  # resolves rescue handlers last-registered-wins. A subclass `discard_on StandardError`
  # registers AFTER this inherited handler, so without re-registering it would catch the
  # interrupt first and re-emit the ERROR line — defeating this fix. See BundleInstallJob
  # and McpPackageReinstallJob.
  def self.discard_interrupt_quietly
    rescue_from(GoodJob::InterruptError) do |error|
      Rails.logger.info("Discarded #{self.class.name} (Job ID: #{job_id}) due to #{error.class.name}: #{error.message}")
    end
  end

  discard_interrupt_quietly

  # Set up correlation ID and context for structured logging
  # This allows tracing operations across multiple jobs and services
  around_perform do |job, block|
    # Generate correlation ID if not already set (e.g., from a parent job)
    Thread.current[:correlation_id] ||= SecureRandom.uuid
    Thread.current[:job_id] = job.job_id

    # Extract session_id from job arguments if present
    if job.arguments.first.is_a?(Hash) && job.arguments.first[:session_id]
      Thread.current[:session_id] = job.arguments.first[:session_id]
    elsif job.respond_to?(:session_id)
      Thread.current[:session_id] = job.session_id
    end

    Rails.logger.info "Starting job #{job.class.name} (job_id: #{job.job_id}, correlation_id: #{Thread.current[:correlation_id]})"

    block.call

    Rails.logger.info "Completed job #{job.class.name} (job_id: #{job.job_id})"
  rescue ActiveRecord::StatementInvalid => e
    # Log database errors with full context
    Rails.logger.error "Database error in #{job.class.name}: #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join("\n")}" if e.backtrace

    # Re-raise so retry_on can handle it
    raise e
  ensure
    # Clean up thread-local variables
    Thread.current[:correlation_id] = nil
    Thread.current[:job_id] = nil
    Thread.current[:session_id] = nil
    Thread.current[:process_pid] = nil
  end
end
