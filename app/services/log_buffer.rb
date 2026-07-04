# Buffer logs in memory and flush periodically to reduce database write contention
class LogBuffer
  include DatabaseRetry

  attr_reader :session

  def initialize(session)
    @session = session
    @buffer = []
    @mutex = Mutex.new
  end

  # Add a log entry to the buffer
  #
  # @param content [String] The log message content
  # @param level [String] The log level (info, error, debug, warning)
  def add(content, level: "info")
    @mutex.synchronize { @buffer << { content: content, level: level } }
  end

  # Flush all buffered logs to the database
  # Returns the number of logs flushed
  def flush
    return 0 if @buffer.empty?

    logs_to_create = @mutex.synchronize do
      buffer = @buffer.dup
      @buffer.clear
      buffer
    end

    # Prepare logs for insertion with validation
    now = Time.current
    logs_to_insert = logs_to_create.map do |log|
      raise ArgumentError, "Log missing content" unless log[:content].present?
      raise ArgumentError, "Log missing level" unless log[:level].present?

      log.merge(
        session_id: @session.id,
        created_at: now,
        updated_at: now
      )
    end

    # Bulk insert logs with retry logic
    with_db_retry do
      @session.logs.insert_all!(logs_to_insert)
    end

    logs_to_create.length
  end

  # Check if buffer has any logs
  def any?
    @mutex.synchronize { @buffer.any? }
  end

  # Get the number of buffered logs
  def size
    @mutex.synchronize { @buffer.size }
  end
end

# Null object pattern for LogBuffer - discards all logs
#
# Used when we need to pass a log buffer dependency but don't want
# the logs to be persisted (e.g., in ProcessLifecycleManager when
# checking for context length errors in transcript without side effects)
class NullLogBuffer
  def add(content, level: "info")
    # Intentionally discards all logs
  end

  def flush
    0
  end

  def any?
    false
  end

  def size
    0
  end
end
