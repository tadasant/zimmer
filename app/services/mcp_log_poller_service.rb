# Service for polling MCP server logs from the Claude CLI cache directory
# MCP logs are stored separately from the main transcript in:
#   - macOS: ~/Library/Caches/claude-cli-nodejs/<sanitized-project-path>/mcp-logs-<server-name>/<timestamp>.jsonl
#   - Linux: ~/.cache/claude-cli-nodejs/<sanitized-project-path>/mcp-logs-<server-name>/<timestamp>.jsonl
#
# Each log file is in JSONL format (one JSON object per line) with timestamps,
# debug/error messages, and connection status information.
#
# This service:
# 1. Finds the MCP log directory for a session based on its working_directory
# 2. Reads all MCP server log files
# 3. Parses and merges log entries by timestamp
# 4. Detects connection status changes (pending -> connected/failed)
# 5. Returns structured data for broadcasting and status tracking
#
class McpLogPollerService
  include DatabaseRetry
  include McpStatusPersisting

  # MCP log patterns for detecting connection status
  CONNECTION_STARTED_PATTERN = /Starting connection with timeout/i
  CONNECTION_SUCCESS_PATTERN = /Successfully connected|Connection established/i
  CONNECTION_FAILED_PATTERN = /Connection failed|Connection timed out/i

  attr_reader :session, :file_system, :min_timestamp

  # @param session [Session] The session to poll logs for
  # @param file_system [Object] File system adapter (for testing)
  # @param min_timestamp [Time, nil] Optional minimum timestamp to filter log entries.
  #   If provided, log entries older than this timestamp will be ignored. This is used
  #   to filter out stale logs from previous session runs when restarting a session.
  #   See GitHub issue #716 for context.
  def initialize(session, file_system: nil, min_timestamp: nil)
    @session = session
    @file_system = file_system || RealFileSystemAdapter.new
    @min_timestamp = min_timestamp
    @logger = StructuredLogger.new({ session_id: session.id, service: "McpLogPollerService" })
  end

  # Poll MCP logs and return structured data
  # @param transcript_content [String, nil] accepted for detector-interface parity
  #   with CodexMcpStatusDetector. Claude Code derives status from per-server log
  #   files, not the transcript, so this argument is ignored.
  # @return [Hash] { logs: Array<Hash>, server_statuses: Hash<String, Hash> }
  #   - logs: Array of log entries with server_name, timestamp, level, message
  #   - server_statuses: Hash of server_name => { status:, error:, connected_at:, failed_at: }
  def poll(transcript_content: nil)
    mcp_log_dir = get_mcp_log_directory
    return { logs: [], server_statuses: {} } unless mcp_log_dir && @file_system.directory?(mcp_log_dir)

    # Find all mcp-logs-* directories
    server_log_dirs = find_server_log_directories(mcp_log_dir)
    return { logs: [], server_statuses: {} } if server_log_dirs.empty?

    all_logs = []
    server_statuses = {}

    server_log_dirs.each do |server_dir|
      server_name = extract_server_name(server_dir)
      next unless server_name

      logs_for_server = read_server_logs(server_dir, server_name)
      all_logs.concat(logs_for_server)

      # Determine server status from logs
      server_statuses[server_name] = determine_server_status(logs_for_server)
    end

    # Sort all logs by timestamp
    # Use epoch time as fallback for missing timestamps to sort them at the beginning
    all_logs.sort_by! { |log| log[:timestamp] || "1970-01-01T00:00:00Z" }

    { logs: all_logs, server_statuses: server_statuses }
  rescue => e
    @logger.error("Error polling MCP logs", error: e.message)
    { logs: [], server_statuses: {} }
  end

  private

  # Get the MCP log directory path based on session's working_directory.
  # Delegates the path computation to the runtime transcript source.
  def get_mcp_log_directory
    working_directory = @session.metadata&.dig("working_directory")
    return nil unless working_directory

    TranscriptRuntime.source_for(@session).mcp_log_paths(working_directory: working_directory).first
  end

  # Find all mcp-logs-* directories in the cache directory
  def find_server_log_directories(mcp_log_dir)
    pattern = File.join(mcp_log_dir, "mcp-logs-*")
    @file_system.glob(pattern).select { |path| @file_system.directory?(path) }
  end

  # Extract server name from directory path
  # e.g., "/path/to/mcp-logs-my-server" => "my-server"
  def extract_server_name(server_dir)
    basename = File.basename(server_dir)
    return nil unless basename.start_with?("mcp-logs-")

    basename.sub("mcp-logs-", "")
  end

  # Read all log files for a server and parse them
  def read_server_logs(server_dir, server_name)
    log_files = @file_system.glob(File.join(server_dir, "*.jsonl")).sort
    return [] if log_files.empty?

    logs = []

    log_files.each do |file|
      content = @file_system.read(file)
      next if content.blank?

      parsed = parse_log_file(content, server_name)
      logs.concat(parsed)
    end

    logs
  end

  # Parse a single MCP log file (JSONL format - one JSON object per line)
  def parse_log_file(content, server_name)
    entries = []

    content.each_line do |line|
      line = line.strip
      next if line.empty?

      begin
        entry = JSON.parse(line)
        entries << {
          server_name: server_name,
          timestamp: entry["timestamp"],
          level: determine_log_level(entry),
          message: extract_log_message(entry),
          raw: entry
        }
      rescue JSON::ParserError => e
        @logger.warn("Failed to parse MCP log line", error: e.message, line: line.truncate(100))
      end
    end

    entries
  end

  # Determine log level from entry
  def determine_log_level(entry)
    return "error" if entry["error"]
    return "debug" if entry["debug"]

    "info"
  end

  # Extract human-readable message from log entry
  def extract_log_message(entry)
    entry["error"] || entry["debug"] || entry["info"] || entry.to_json
  end

  # Determine server connection status from logs
  # Only considers log entries newer than min_timestamp (if set) to filter out stale logs
  # from previous session runs. This is critical for session restarts - see GitHub issue #716.
  #
  # Processes all log entries to find the final connection state. Claude Code has built-in
  # retry logic for MCP connections, so a transient failure followed by success should be
  # treated as connected (not failed). The final state after processing all logs is returned.
  #
  # @return [Hash] { status:, error:, connected_at:, failed_at: }
  def determine_server_status(logs)
    status = { status: "pending" }
    # Collect all error messages leading up to failure for root cause context
    error_messages = []

    logs.each do |log|
      # Skip entries older than min_timestamp to filter out stale logs from previous runs
      # This allows MCP connections to be re-established fresh on restart
      if @min_timestamp && log[:timestamp]
        begin
          log_time = Time.parse(log[:timestamp])
          next if log_time < @min_timestamp
        rescue ArgumentError
          # If timestamp parsing fails, include the entry (safer to include than exclude)
        end
      end

      message = log[:message] || ""
      timestamp = log[:timestamp]
      level = log[:level]

      # Collect error-level messages for context (these might contain root cause)
      # Also collect any message that looks like an error (contains "error", "failed", etc.)
      if message.present? && (level == "error" || message.match?(/error|failed|timeout|refused|unauthorized/i))
        error_messages << message
      end

      if message.match?(CONNECTION_SUCCESS_PATTERN)
        status = { status: "connected", connected_at: timestamp }
        error_messages.clear # Reset errors on successful connection
      elsif message.match?(CONNECTION_FAILED_PATTERN)
        # Combine all error messages for a more complete picture
        # The last error is usually "Connection failed", but earlier errors may have root cause
        combined_error = error_messages.uniq.join(" | ")
        status = { status: "failed", error: combined_error, failed_at: timestamp }
        # Don't break - continue processing to see if a retry succeeded.
        # Claude Code has built-in retry logic for MCP connections, so a failure
        # followed by a success should be treated as connected.
      end
    end

    status
  end
end
