# frozen_string_literal: true

# StructuredLogger provides helper methods for structured logging with contextual data
# Use this service to log operations with consistent formatting and metadata
#
# Example usage:
#   logger = StructuredLogger.new(session_id: 123, process_pid: 456)
#   logger.info("Processing started", stage: "initialization")
#   logger.error("Failed to connect", error: e.message, retry_count: 3)
#
class StructuredLogger
  attr_reader :context

  def initialize(context = {}, logger: nil)
    @context = context.symbolize_keys
    @logger = logger || Rails.logger
  end

  # Log at info level with context
  def info(message, additional_context = {})
    log(:info, message, additional_context)
  end

  # Log at debug level with context
  def debug(message, additional_context = {})
    log(:debug, message, additional_context)
  end

  # Log at warn level with context
  def warn(message, additional_context = {})
    log(:warn, message, additional_context)
  end

  # Log at error level with context.
  #
  # Error-level logs are, by policy, things that should not happen and that we
  # want to be noisy about (see the logging philosophy in CLAUDE.md), so they
  # are also surfaced to GlitchTip via ErrorReporter. When an exception object
  # is supplied in the context (under :exception or an Exception-valued :error),
  # it is reported with its backtrace; otherwise the message is reported.
  def error(message, additional_context = {})
    log(:error, message, additional_context)
    report_error_to_sentry(message, additional_context)
  end

  # Set context for the current thread (useful for propagating across method calls)
  def with_context(additional_context = {})
    previous_context = {
      correlation_id: Thread.current[:correlation_id],
      session_id: Thread.current[:session_id],
      job_id: Thread.current[:job_id],
      process_pid: Thread.current[:process_pid]
    }

    begin
      apply_context_to_thread(additional_context)
      yield
    ensure
      restore_context_to_thread(previous_context)
    end
  end

  # Create a child logger with merged context
  def child(additional_context = {})
    self.class.new(@context.merge(additional_context))
  end

  private

  def log(level, message, additional_context = {})
    # Merge instance context with additional context
    full_context = @context.merge(additional_context.symbolize_keys)

    # Format message with all context inline
    # The StructuredLogFormatter will also include thread-local context set by ApplicationJob
    formatted_message = if full_context.empty?
      message
    else
      "#{message} | #{full_context.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    end

    @logger.public_send(level, formatted_message)
  end

  # Surface error-level logs to GlitchTip. Prefer the real exception object
  # (carries a backtrace) when the caller passes one; fall back to a message.
  def report_error_to_sentry(message, additional_context)
    full_context = @context.merge(additional_context.symbolize_keys)
    exception = full_context[:exception]
    exception ||= full_context[:error] if full_context[:error].is_a?(Exception)

    if exception.is_a?(Exception)
      ErrorReporter.report_exception(exception, context: full_context.except(:exception, :error))
    else
      ErrorReporter.report_message(message, context: full_context)
    end
  end

  def apply_context_to_thread(context)
    Thread.current[:correlation_id] ||= context[:correlation_id] if context[:correlation_id]
    Thread.current[:session_id] = context[:session_id] if context[:session_id]
    Thread.current[:job_id] = context[:job_id] if context[:job_id]
    Thread.current[:process_pid] = context[:process_pid] if context[:process_pid]
  end

  def restore_context_to_thread(context)
    Thread.current[:correlation_id] = context[:correlation_id]
    Thread.current[:session_id] = context[:session_id]
    Thread.current[:job_id] = context[:job_id]
    Thread.current[:process_pid] = context[:process_pid]
  end
end
