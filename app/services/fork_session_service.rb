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

  # Waits between clone-copy attempts. Their count is the retry budget: three
  # attempts, ~2.5s of backoff in the worst case.
  #
  # The budget is deliberately small, because a retry is not free — each one
  # re-walks the whole tree, and a user-initiated fork runs inside the request
  # that asked for it. A longer ladder would turn a fork that cannot be made
  # into a request that hangs. It rides out a tree being written to, not a tree
  # being rebuilt: a copy racing a `bundle install` that runs for half a minute
  # can still exhaust the budget and fail, loudly, which is the right outcome.
  COPY_RETRY_DELAYS = [ 0.5, 2.0 ].freeze

  # Installed-dependency trees, excludable from a fork's copy by callers that
  # know the fork will never build or boot anything. They are the bulk of a
  # clone — `vendor/bundle` alone is ~300 gem directories in Zimmer's own repo —
  # and every second the copy spends walking them is a second the source tree
  # can change underneath it.
  DEPENDENCY_DIRECTORIES = [ "vendor/bundle", "**/node_modules" ].freeze

  # What a fork's title is built from — see #generate_forked_title.
  FORK_TITLE_PREFIX = "Fork of "
  TITLE_OMISSION = "…"

  # The cap a generated title has to fit, read off Session's own validator
  # rather than restated here: a change to the model's limit must not leave this
  # service composing titles the model then rejects, which fails the fork
  # deterministically. It reads the `maximum` off every length validator on
  # :title and takes the smallest, so a context-scoped one narrows the budget
  # too; nil means no length validator declares a maximum, and nothing is
  # truncated.
  def self.title_length_limit
    Session.validators_on(:title)
      .select { |validator| validator.is_a?(ActiveModel::Validations::LengthValidator) }
      .filter_map { |validator| validator.options[:maximum] }
      .min
  end

  attr_reader :source_session, :message_index, :file_system, :extra_metadata, :copy_exclusions

  # @param extra_metadata [Hash] merged into the forked session's metadata at
  #   CREATE time. Callers that need the fork classified from its very first
  #   commit must use this rather than updating it afterwards: `Session`'s
  #   after_create_commit broadcasts a card to every open dashboard, and it has
  #   already fired by the time an update could add the marker.
  # @param copy_exclusions [Array<String>] fnmatch patterns, relative to the
  #   clone root, to leave out of the copied clone. Empty by default: a
  #   user-initiated fork is a working session and wants the tree it forked.
  def initialize(source_session:, message_index:, file_system: nil, extra_metadata: {}, copy_exclusions: [])
    @source_session = source_session
    @message_index = message_index
    @file_system = file_system || RealFileSystemAdapter.new
    @extra_metadata = extra_metadata || {}
    @copy_exclusions = copy_exclusions || []
    @logger = StructuredLogger.new({ session_id: source_session.id, service: "ForkSessionService" })
  end

  # The transcript as this service sees it: one JSON object per line, with blank
  # and unparseable lines dropped. `message_index` is an index into THIS, not
  # into the raw line count — see #validate_inputs, which bounds it against this
  # length, and #truncate_transcript, which slices it.
  #
  # Exposed because a caller computing a fork point from a session's line count
  # is computing it in the wrong index space: one blank line anywhere puts the
  # last raw index out of range.
  def self.parsed_messages(transcript)
    return [] if transcript.blank?
    return transcript if transcript.is_a?(Array)

    transcript.lines.filter_map do |line|
      JSON.parse(line.strip)
    rescue JSON::ParserError
      nil
    end
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
    unless forked_session
      # The clone was copied in full before this point, and no record was
      # written to claim it — so nothing but OrphanCloneFilesystemCleanupJob's
      # 48h sweep would ever collect it.
      discard_partial_clone(new_clone_path)
      return Result.new(success?: false, error: "Failed to create forked session record")
    end

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
    @parsed_transcript ||= self.class.parsed_messages(source_session.transcript)
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

    copy_clone_directory(source_clone_path, new_clone_path)

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
    # Whatever got written before the failure belongs to nobody:
    # OrphanCloneFilesystemCleanupJob ignores anything younger than its 48h
    # threshold, so a partial clone left here sits on disk for two days.
    discard_partial_clone(new_clone_path)
    nil
  end

  # Copies the source clone, retrying the whole copy when a file vanishes from
  # under it.
  #
  # The source is a LIVE working tree. Its own agent process, its jobs
  # (BundleInstallJob rewrites `vendor/bundle` wholesale) and the archive
  # pipeline all keep writing to it while the copy walks it, and a recursive
  # copy enumerates a directory before it stats the entries it found — so a file
  # that disappears in between aborts the entire copy with ENOENT. That is
  # transient by construction: the next attempt enumerates a tree that no longer
  # contains the file.
  #
  # Only that case is retried. Any other errno — EACCES, ENOSPC — and an ENOENT
  # raised because the source clone itself is gone (the archive pipeline deleted
  # it) will not fix itself, and must fail on the first hit rather than spend the
  # retry budget first.
  def copy_clone_directory(source_clone_path, new_clone_path)
    attempt = 0

    begin
      attempt += 1
      @logger.info("Copying clone directory",
        source: source_clone_path,
        destination: new_clone_path,
        attempt: attempt,
        exclusions: copy_exclusions
      )

      # Use file_system.cp_r for deep copy (allows mocking in tests)
      file_system.cp_r(source_clone_path, new_clone_path, exclude: copy_exclusions)
    rescue Errno::ENOENT => e
      delay = COPY_RETRY_DELAYS[attempt - 1]
      raise if delay.nil? || !retryable_copy_target?(source_clone_path, new_clone_path)

      # Deliberately .info, not .warn/.error: this is the expected cost of
      # copying a live tree, and the fork has not failed yet. The terminal case
      # still logs .error from #create_forked_clone, and still pages.
      @logger.info("Retrying clone copy after a source file vanished mid-copy",
        error: e.message,
        attempt: attempt,
        retry_in_seconds: delay
      )

      # Restart from an empty destination. This is a precondition, not a
      # courtesy: cp_r given a destination that already exists copies INTO it as
      # a subdirectory, and a pruned copy merges into it — so a retry over a
      # surviving partial tree produces a nested or stale clone rather than a
      # failure. rm_rf reports nothing when it removes only part of a tree, so
      # the check is on the result, not on the call.
      discard_partial_clone(new_clone_path)
      raise if file_system.exists?(new_clone_path)

      sleep(delay)
      retry
    end
  end

  # An ENOENT is only worth another attempt while both ends of the copy are
  # still there. A source clone the archive pipeline deleted, or a clones
  # directory that went away under us, will not come back.
  def retryable_copy_target?(source_clone_path, new_clone_path)
    file_system.directory?(source_clone_path) && file_system.directory?(File.dirname(new_clone_path))
  end

  # rm_rf on a path that was never created is a no-op, so this needs no guard
  # beyond having a path at all — and the destination may be a partially written
  # tree, a bare directory, or nothing.
  def discard_partial_clone(path)
    file_system.rm_rf(path) if path.present?
  rescue => e
    @logger.warn("Failed to remove partial forked clone", path: path, error: e.message)
  end

  def cleanup_inherited_files(clone_path)
    # Remove the inherited stderr log - the new session will create its own. The
    # filename comes from the runtime the fork will be driven by, so a forked
    # Codex session sheds codex_stderr.log rather than a Claude filename it never
    # writes.
    adapter_class = RuntimeRegistry.cli_adapter_class_for(source_session.agent_runtime)

    stderr_log = adapter_class.stderr_log_path(clone_path)
    file_system.rm_rf(stderr_log) if file_system.exists?(stderr_log)

    # If there's a subdirectory, also clean up there
    if source_session.subdirectory.present?
      subdir_stderr_log = adapter_class.stderr_log_path(File.join(clone_path, source_session.subdirectory))
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

  # Returning nil has to mean "no record exists", because the caller disposes of
  # the copied clone on that answer — so the session and its two log rows are
  # written in one transaction. Without it, a log insert that fails leaves a
  # committed Session whose metadata names a clone the caller then deletes, and
  # a retried block creates a second Session for the same fork.
  def create_forked_session(new_clone_path:, new_working_directory:, new_session_id:, truncated_transcript:)
    with_db_retry do
      Session.transaction do
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
        }.merge(extra_metadata)

        # The fork copies the source's server list verbatim, so it has to copy
        # the reason that list is empty too. This metadata is built from scratch
        # rather than inherited, so without carrying the marker across,
        # McpServerBackfill reads the fork's empty column as an accident and
        # restores the agent root's defaults — handing the fork exactly the
        # servers the source declined.
        if source_session.mcp_servers_explicitly_empty?
          new_metadata[Session::EXPLICIT_EMPTY_MCP_SERVERS_KEY] = true
        end

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
    end
  rescue => e
    @logger.error("Failed to create forked session record", error: e.message)
    nil
  end

  # A fork's title is the source's under a prefix — and it has to survive
  # Session's own length validation, which the source title may have spent all
  # of. A source title over 92 characters composes one over the cap, and titles
  # that long are legal and routine, so the base is truncated to whatever the
  # prefix leaves, with an ellipsis so the result still reads as the session it
  # forked.
  def generate_forked_title
    base_title = source_session.title.presence || "Session #{source_session.id}"
    limit = self.class.title_length_limit
    return "#{FORK_TITLE_PREFIX}#{base_title}" if limit.nil?

    # A cap too small to hold the prefix and an omission leaves nothing to
    # budget with, so the whole composed title is truncated instead.
    budget = limit - FORK_TITLE_PREFIX.length
    return "#{FORK_TITLE_PREFIX}#{base_title}".truncate(limit, omission: TITLE_OMISSION) if budget < TITLE_OMISSION.length

    "#{FORK_TITLE_PREFIX}#{base_title.truncate(budget, omission: TITLE_OMISSION)}"
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
