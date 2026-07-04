# frozen_string_literal: true

# Log Queries Documentation
# ==========================
#
# This file documents common queries for searching structured logs.
# Logs are formatted as JSON with the following fields:
#
# Required fields:
#   - timestamp: ISO8601 timestamp (e.g., "2025-01-15T10:30:45Z")
#   - severity: Log level (DEBUG, INFO, WARN, ERROR, FATAL)
#   - message: Log message content
#
# Optional context fields:
#   - correlation_id: UUID for tracing related operations
#   - session_id: Database ID of the session
#   - job_id: ActiveJob job ID
#   - process_pid: OS process ID
#   - progname: Program/component name
#
# Example log entry:
# {
#   "timestamp": "2025-01-15T10:30:45Z",
#   "severity": "INFO",
#   "correlation_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
#   "session_id": 123,
#   "job_id": "abc123",
#   "process_pid": 45678,
#   "message": "Processing started | stage=initialization"
# }
#
# Common Queries
# ==============
#
# 1. Find all logs for a specific session:
#    grep '"session_id":123' log/production.log | jq .
#
# 2. Find all logs for a specific correlation ID:
#    grep '"correlation_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890"' log/production.log | jq .
#
# 3. Find all errors for a session:
#    grep '"session_id":123' log/production.log | grep '"severity":"ERROR"' | jq .
#
# 4. Trace a job's execution:
#    grep '"job_id":"abc123"' log/production.log | jq -r '[.timestamp, .severity, .message] | @tsv'
#
# 5. Find all logs for a specific process:
#    grep '"process_pid":45678' log/production.log | jq .
#
# 6. Find all database errors:
#    grep '"severity":"ERROR"' log/production.log | grep -i database | jq .
#
# 7. Get timeline of a correlation ID (sorted by timestamp):
#    grep '"correlation_id":"a1b2c3d4-e5f6-7890"' log/production.log | jq -s 'sort_by(.timestamp)'
#
# 8. Count errors by session:
#    grep '"severity":"ERROR"' log/production.log | jq -r .session_id | sort | uniq -c
#
# 9. Find slow operations (assuming duration is logged):
#    grep duration log/production.log | jq 'select(.duration > 5000)'
#
# 10. Get all job starts and completions for a session:
#     grep '"session_id":123' log/production.log | grep -E 'Starting job|Completed job' | jq -r '[.timestamp, .message] | @tsv'
#
# Ruby API for Log Analysis
# ==========================
#
# You can also query logs programmatically using Ruby:

module LogQueries
  # Parse a JSON log line
  def self.parse_line(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  # Find all logs for a session
  # Uses lazy enumeration to avoid loading entire log file into memory
  def self.logs_for_session(session_id, log_file = "log/#{Rails.env}.log")
    return [] unless File.exist?(log_file)

    results = []
    File.foreach(log_file) do |line|
      parsed = parse_line(line)
      results << parsed if parsed && parsed["session_id"] == session_id
    end
    results
  end

  # Find all logs for a correlation ID
  # Uses lazy enumeration to avoid loading entire log file into memory
  def self.logs_for_correlation(correlation_id, log_file = "log/#{Rails.env}.log")
    return [] unless File.exist?(log_file)

    results = []
    File.foreach(log_file) do |line|
      parsed = parse_line(line)
      results << parsed if parsed && parsed["correlation_id"] == correlation_id
    end
    results
  end

  # Find all errors
  # Uses lazy enumeration to avoid loading entire log file into memory
  def self.errors(log_file = "log/#{Rails.env}.log")
    return [] unless File.exist?(log_file)

    results = []
    File.foreach(log_file) do |line|
      parsed = parse_line(line)
      results << parsed if parsed && parsed["severity"] == "ERROR"
    end
    results
  end

  # Get log timeline for a correlation ID (sorted by timestamp)
  def self.timeline_for_correlation(correlation_id, log_file = "log/#{Rails.env}.log")
    logs_for_correlation(correlation_id, log_file).sort_by { |log| log["timestamp"] }
  end

  # Example usage in Rails console:
  #   LogQueries.logs_for_session(123)
  #   LogQueries.logs_for_correlation("a1b2c3d4-e5f6-7890")
  #   LogQueries.errors
  #   LogQueries.timeline_for_correlation("a1b2c3d4-e5f6-7890")
end
