# frozen_string_literal: true

require "fileutils"
require "path_sanitizer"

# Service for forking a session at a specific message in the conversation.
#
# Forking creates a new session that is a "carbon copy" of the source session
# up to and including the specified message index. The new session:
# - Has a new clone directory (copy of the source clone's git state)
# - Has a new session_id UUID for Claude CLI
# - Has a truncated transcript containing only messages up to the fork point
# - Starts in needs_input status, ready for user to provide a new prompt
#
# This enables exploring alternative conversation branches without affecting
# the original session.
#
# @example
#   result = ForkSessionService.call(
#     source_session: session,
#     message_index: 5,
#     file_system: RealFileSystemAdapter.new
#   )
#   if result.success?
#     redirect_to result.forked_session
#   else
#     flash[:alert] = result.error
#   end
class ForkSessionService
  include DatabaseRetry

  # Result object returned by the service
  Result = Struct.new(:success?, :forked_session, :error, keyword_init: true)

  attr_reader :source_session, :message_index, :file_system

  def initialize(source_session:, message_index:, file_system: nil)
    @source_session = source_session
    @message_index = message_index
    @file_system = file_system || RealFileSystemAdapter.new
    @logger = StructuredLogger.new({ session_id: source_session.id, service: "ForkSessionService" })
  end

  def self.call(...)
    new(...).call
  end

  def call
    # Validate inputs
    validation_error = validate_inputs
    return Result.new(success?: false, error: validation_error) if validation_error

    # Parse and truncate transcript
    truncated_transcript = truncate_transcript
    return Result.new(success?: false, error: "Failed to truncate transcript") unless truncated_transcript

    # Create new clone directory
    new_clone_path = create_forked_clone
    return Result.new(success?: false, error: "Failed to create forked clone directory") unless new_clone_path

    # Generate new session_id for Claude CLI
    new_session_id = SecureRandom.uuid

    # Calculate new working directory
    new_working_directory = calculate_working_directory(new_clone_path)

    # Create new session record
    forked_session = create_forked_session(
      new_clone_path: new_clone_path,
      new_working_directory: new_working_directory,
      new_session_id: new_session_id,
      truncated_transcript: truncated_transcript
    )
    return Result.new(success?: false, error: "Failed to create forked session record") unless forked_session

    # Write truncated transcript to the new location
    write_transcript_success = write_transcript_file(
      new_working_directory: new_working_directory,
      new_session_id: new_session_id,
      truncated_transcript: truncated_transcript
    )
    unless write_transcript_success
      # Cleanup on failure
      cleanup_on_failure(forked_session, new_clone_path)
      return Result.new(success?: false, error: "Failed to write transcript file")
    end

    # Log success
    @logger.info("Session forked successfully",
      source_session_id: source_session.id,
      forked_session_id: forked_session.id,
      message_index: message_index,
      transcript_lines: truncated_transcript.lines.count
    )

    Result.new(success?: true, forked_session: forked_session)
  rescue => e
    @logger.error("Failed to fork session", error: e.message, backtrace: e.backtrace&.first(5))
    Result.new(success?: false, error: "Failed to fork session: #{e.message}")
  end

  private

  def validate_inputs
    # Source session must exist and have a transcript
    return "Source session has no transcript" if source_session.transcript.blank?

    # Source session must have clone metadata
    source_clone_path = source_session.metadata&.dig("clone_path")
    return "Source session has no clone path" if source_clone_path.blank?

    # Clone must exist
    return "Source clone directory does not exist" unless file_system.directory?(source_clone_path)

    # Parse transcript and validate message_index
    parsed = parse_transcript
    return "Failed to parse transcript" if parsed.nil?
    return "Message index #{message_index} is out of range (transcript has #{parsed.length} messages)" if message_index < 0 || message_index >= parsed.length

    nil # No error
  end

  def parse_transcript
    return @parsed_transcript if defined?(@parsed_transcript)

    @parsed_transcript = source_session.transcript.lines.map do |line|
      JSON.parse(line.strip)
    rescue JSON::ParserError
      nil
    end.compact
  end

  def truncate_transcript
    parsed = parse_transcript
    return nil unless parsed

    # Keep messages from index 0 to message_index (inclusive)
    truncated = parsed[0..message_index]
    @truncated_message_count = truncated.length

    # Convert back to JSONL format
    truncated.map { |msg| JSON.generate(msg) }.join("\n") + "\n"
  rescue => e
    @logger.error("Failed to truncate transcript", error: e.message)
    nil
  end

  def create_forked_clone
    source_clone_path = source_session.metadata["clone_path"]

    # Generate new clone path with similar naming convention
    timestamp = Time.now.to_i
    random = SecureRandom.hex(4)
    repo_name = File.basename(source_clone_path).split("-").first
    branch = source_session.branch || "main"

    base_path = ClonesDirectory.base
    file_system.mkdir_p(base_path)

    new_clone_path = File.join(base_path, "#{repo_name}-#{branch}-#{timestamp}-#{random}")

    # Copy the source clone directory
    @logger.info("Copying clone directory", source: source_clone_path, destination: new_clone_path)

    # Use file_system.cp_r for deep copy (allows mocking in tests)
    file_system.cp_r(source_clone_path, new_clone_path)

    # Clean up Claude-specific files that shouldn't be inherited
    cleanup_inherited_files(new_clone_path)

    # Generate MCP configuration for the forked session
    # This is critical because:
    # 1. The source clone's .mcp.json may reference old paths
    # 2. The forked session will use --resume mode which doesn't regenerate MCP config
    # 3. Without this, MCP servers won't be available in the forked session
    generate_mcp_config(new_clone_path)

    new_clone_path
  rescue => e
    @logger.error("Failed to create forked clone", error: e.message)
    nil
  end

  def cleanup_inherited_files(clone_path)
    # Remove old stderr log - new session will create its own
    stderr_log = File.join(clone_path, "claude_stderr.log")
    file_system.rm_rf(stderr_log) if file_system.exists?(stderr_log)

    # If there's a subdirectory, also clean up there
    if source_session.subdirectory.present?
      subdir_stderr_log = File.join(clone_path, source_session.subdirectory, "claude_stderr.log")
      file_system.rm_rf(subdir_stderr_log) if file_system.exists?(subdir_stderr_log)
    end
  end

  # Generate MCP configuration and inject skills for the forked session using AIR CLI
  def generate_mcp_config(new_clone_path)
    working_directory = calculate_working_directory(new_clone_path)

    air_service = AirPrepareService.new(
      session: source_session,
      working_directory: working_directory,
      file_system: file_system
    )
    if source_session.mcp_servers.present? || source_session.catalog_skills.present? || source_session.catalog_hooks.present? || source_session.catalog_plugins.present?
      air_service.prepare!
    else
      air_service.ensure_baseline_mcp_config!
    end

    @logger.info("AIR prepare completed for forked session",
      working_directory: working_directory,
      mcp_servers: source_session.mcp_servers
    )
  rescue => e
    # Log the error but don't fail the fork - config can be regenerated later
    @logger.warn("Failed to run AIR prepare for forked session",
      error: e.message,
      mcp_servers: source_session.mcp_servers
    )
  end

  def calculate_working_directory(new_clone_path)
    if source_session.subdirectory.present?
      File.join(new_clone_path, source_session.subdirectory)
    else
      new_clone_path
    end
  end

  def create_forked_session(new_clone_path:, new_working_directory:, new_session_id:, truncated_transcript:)
    with_db_retry do
      # Build metadata for the new session
      # IMPORTANT: runtime_started must be set to true because we're creating a
      # transcript file with the new session_id. When the user sends their first
      # follow-up message, AgentSessionJob checks this flag to determine whether
      # to use --resume vs --session-id. Since the transcript file already exists,
      # Claude CLI MUST use --resume mode, otherwise it will fail with
      # "Session ID already in use" error.
      new_metadata = {
        "clone_path" => new_clone_path,
        "working_directory" => new_working_directory,
        "full_clone_path" => new_working_directory,
        "forked_from_session_id" => source_session.id,
        "forked_at_message_index" => message_index,
        "broadcast_message_count" => @truncated_message_count, # Set to transcript length to prevent replay
        "runtime_started" => true # Required for --resume mode on first follow-up
      }

      # Create the forked session
      forked_session = Session.create!(
        agent_runtime: source_session.agent_runtime,
        git_root: source_session.git_root,
        branch: source_session.branch,
        subdirectory: source_session.subdirectory,
        execution_provider: source_session.execution_provider,
        mcp_servers: source_session.mcp_servers,
        catalog_skills: source_session.catalog_skills,
        catalog_hooks: source_session.catalog_hooks,
        catalog_plugins: source_session.catalog_plugins,
        config: source_session.config,
        goal: source_session.goal,
        is_autonomous: source_session.is_autonomous,
        session_notes: source_session.session_notes,
        session_notes_updated_at: source_session.session_notes_updated_at,
        session_id: new_session_id,
        status: :needs_input,
        transcript: truncated_transcript,
        metadata: new_metadata,
        title: generate_forked_title
      )

      # Create a log entry for the forked session
      forked_session.logs.create!(
        content: "Session forked from session ##{source_session.id} at message #{message_index + 1}",
        level: "info"
      )

      # Also log in the source session
      source_session.logs.create!(
        content: "Session forked to session ##{forked_session.id} at message #{message_index + 1}",
        level: "info"
      )

      forked_session
    end
  rescue => e
    @logger.error("Failed to create forked session record", error: e.message)
    nil
  end

  def generate_forked_title
    base_title = source_session.title.presence || "Session #{source_session.id}"
    "Fork of #{base_title}"
  end

  def write_transcript_file(new_working_directory:, new_session_id:, truncated_transcript:)
    # Calculate transcript directory path using Claude's naming convention
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(new_working_directory)
    transcript_dir = File.join(claude_projects_dir, sanitized_path)

    # Ensure directory exists
    file_system.mkdir_p(transcript_dir)

    # Write the transcript file
    transcript_file = File.join(transcript_dir, "#{new_session_id}.jsonl")
    @logger.info("Writing transcript file", path: transcript_file, lines: truncated_transcript.lines.count)

    file_system.write(transcript_file, truncated_transcript)

    true
  rescue => e
    @logger.error("Failed to write transcript file", error: e.message)
    false
  end

  def cleanup_on_failure(forked_session, new_clone_path)
    # Delete the forked session if it was created
    forked_session&.destroy if forked_session&.persisted?

    # Delete the clone directory if it exists
    file_system.rm_rf(new_clone_path) if new_clone_path && file_system.directory?(new_clone_path)
  rescue => e
    @logger.error("Failed to cleanup after fork failure", error: e.message)
  end
end
