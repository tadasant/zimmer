# frozen_string_literal: true

# StructuredLogFormatter formats log messages as JSON with contextual metadata
# This enables better log aggregation, searching, and correlation across services
class StructuredLogFormatter < Logger::Formatter
  def call(severity, timestamp, progname, msg)
    log_entry = {
      timestamp: timestamp.iso8601,
      severity: severity,
      progname: progname,
      message: format_message(msg)
    }

    # Add correlation context if available
    if Thread.current[:correlation_id]
      log_entry[:correlation_id] = Thread.current[:correlation_id]
    end

    if Thread.current[:session_id]
      log_entry[:session_id] = Thread.current[:session_id]
    end

    if Thread.current[:job_id]
      log_entry[:job_id] = Thread.current[:job_id]
    end

    if Thread.current[:process_pid]
      log_entry[:process_pid] = Thread.current[:process_pid]
    end

    "#{log_entry.to_json}\n"
  end

  private

  def format_message(msg)
    case msg
    when String
      msg
    when Exception
      "#{msg.message} (#{msg.class})\n#{msg.backtrace&.join("\n")}"
    else
      msg.inspect
    end
  end
end

# Configure structured logging in production and development
# Test environment uses standard formatter for easier reading
unless Rails.env.test?
  Rails.application.configure do
    config.log_formatter = StructuredLogFormatter.new
  end
end
