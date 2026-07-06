# Service for polling agent transcript files and broadcasting updates.
#
# Runtime-agnostic orchestrator: it resolves a TranscriptSource (file/format
# layer) and TranscriptNormalizer (semantic layer) for the session via
# TranscriptRuntime, then drives the polling loop, subagent detection, MCP log
# fold-in, and broadcast throttling on top of them.
class TranscriptPollerService
  include DatabaseRetry

  attr_reader :file_system, :broadcast_service, :mcp_status_detector

  def initialize(session, file_system: nil, broadcast_service: nil, mcp_status_detector: nil)
    @session = session
    @file_system = file_system || RealFileSystemAdapter.new
    @broadcast_service = broadcast_service || BroadcastService.new
    # Resolve the runtime-specific transcript I/O (source) and semantics
    # (normalizer) for this session. The poller stays runtime-agnostic and
    # routes all file/format and event-shape decisions through these.
    @source = TranscriptRuntime.source_for(session, file_system: @file_system)
    @normalizer = TranscriptRuntime.normalizer_for(session)
    # Parse job_started_at from session metadata to filter stale MCP logs (see issue #716)
    # This ensures that when a session is restarted, old MCP failure logs don't cause
    # immediate failure before the new MCP connection has a chance to succeed.
    min_timestamp = job_started_at_from_metadata(session)
    # Resolve the runtime's MCP status detector: Claude Code reads per-server log
    # files (McpLogPollerService); Codex derives status from the rollout transcript
    # (CodexMcpStatusDetector). Both share the poll/update_session_mcp_status contract.
    @mcp_status_detector = mcp_status_detector ||
      RuntimeRegistry.for(session&.agent_runtime).mcp_status_detector_class.new(session, file_system: @file_system, min_timestamp: min_timestamp)
    @logger = StructuredLogger.new({ session_id: session.id, service: "TranscriptPollerService" })
  end

  # Poll the transcript file and broadcast new messages
  # @return [Boolean, nil] Returns:
  #   - true: Successfully polled and processed transcript
  #   - false: Error occurred (exception or missing working_directory)
  #   - nil: Waiting state (transcript directory or files not yet created)
  def poll_and_broadcast
    # Get the transcript directory
    transcript_dir = get_transcript_directory

    unless transcript_dir
      Rails.logger.warn "Could not determine transcript directory for session #{@session.id}"
      return false
    end

    # Track metadata updates to batch them
    metadata_updates = {}

    unless @file_system.directory?(transcript_dir)
      # Log only once when directory is missing
      unless @session.metadata&.dig("transcript_waiting_logged")
        with_db_retry do
          @session.logs.create!(
            content: "Waiting for Claude CLI to create transcript directory...",
            level: "info"
          )
        end
        metadata_updates["transcript_waiting_logged"] = true
      end

      # Batch update metadata if we have changes
      if metadata_updates.any?
        with_db_retry do
          @session.reload
          @session.update_columns(
            metadata: (@session.metadata || {}).merge(metadata_updates)
          )
        end
      end
      # Return nil (not false) to indicate "waiting" state vs actual failure
      # This allows the caller to distinguish between expected waiting and real problems
      return nil
    end

    # Find the main transcript file using session_id
    # The main transcript is named <session_id>.jsonl
    # We avoid using max_by mtime because nested agents (agent-*.jsonl) may have more recent mtime
    main_transcript_file = find_main_transcript_file(transcript_dir)

    if main_transcript_file.nil?
      # Log only once when files are missing
      unless @session.metadata&.dig("transcript_files_waiting_logged")
        with_db_retry do
          @session.logs.create!(
            content: "Transcript directory created, waiting for transcript files...",
            level: "info"
          )
        end
        metadata_updates["transcript_files_waiting_logged"] = true
      end

      # Batch update metadata if we have changes
      if metadata_updates.any?
        with_db_retry do
          @session.reload
          @session.update_columns(
            metadata: (@session.metadata || {}).merge(metadata_updates)
          )
        end
      end
      # Return nil (not false) to indicate "waiting" state vs actual failure
      return nil
    end

    # Log when we first start reading
    unless @session.metadata&.dig("transcript_reading_started_logged")
      with_db_retry do
        @session.logs.create!(
          content: "Transcript file found, streaming conversation in real-time...",
          level: "info"
        )
      end
      metadata_updates["transcript_reading_started_logged"] = true
    end

    # Read the transcript content. Routing through the source (not the raw file
    # system) lets runtimes transparently decode their on-disk format — e.g.
    # Codex stores compressed `.jsonl.zst` rollouts that the source decompresses.
    transcript_content = @source.read(main_transcript_file)

    # Poll and store subagent transcripts (agent-*.jsonl files)
    # Then update metadata from the main transcript
    poll_subagent_transcripts
    update_subagent_metadata_from_transcript(transcript_content)

    # Poll MCP server logs and update connection status.
    # Claude Code reads its CLI cache log files; Codex derives status from the
    # rollout transcript content, so pass it through to the runtime's detector.
    poll_mcp_logs(transcript_content)

    # Parse the transcript to find messages
    new_messages = parse_transcript_lines(transcript_content)

    # Capture the runtime's own session id from the transcript and persist it
    # when it differs from what we stored at spawn. This is essential for Codex:
    # the CLI ignores the Zimmer-supplied session id and mints its own rollout/thread
    # UUID (emitted on the `session_meta` line), and that UUID is what
    # `codex exec resume <uuid>` requires. Without capturing it, resume targets
    # the stale Zimmer UUID and Codex aborts with "no rollout found for thread id",
    # failing every follow-up turn. Gated on the runtime trait so it runs only for
    # runtimes that mint their own id (#3884). Claude honors the Zimmer-supplied id, so
    # capturing is both unnecessary and actively harmful there: a forked Claude
    # session's transcript is copied from its source and its early lines carry the
    # SOURCE session's id, which would overwrite the fork's id, collide with the
    # unique session_id index (RecordNotUnique), and fail every poll until the
    # session is wrongly marked transcript_unavailable.
    capture_runtime_session_id!(new_messages)

    # Track how many messages we've already broadcast.
    # When broadcast_message_count is nil (cleared during session recovery/restart),
    # recalculate from the stored transcript to avoid re-broadcasting the entire
    # conversation history. This prevents the "message replay" bug where opening
    # a recovered session shows all old messages rapidly streaming in again.
    broadcast_count = @session.metadata&.dig("broadcast_message_count")
    if broadcast_count.nil?
      stored_count = @session.parsed_transcript&.length || 0
      if stored_count > 0
        @logger.info("broadcast_message_count was nil, recovering from stored transcript", stored_count: stored_count)
        broadcast_count = stored_count
        metadata_updates["broadcast_message_count"] = stored_count
      else
        broadcast_count = 0
      end
    end

    # Only broadcast new messages
    messages_to_broadcast = new_messages[broadcast_count..]

    # Check if any of the new messages are user messages that match the sent_message
    # If so, clear the sent_message from metadata since it's now in the transcript
    if messages_to_broadcast&.any?
      clear_sent_message_if_found(messages_to_broadcast, metadata_updates)
    end

    # Broadcast new messages
    if messages_to_broadcast&.any?
      @logger.info("Broadcasting new messages", new_count: messages_to_broadcast.length, total: new_messages.length, already_broadcast: broadcast_count)
      broadcast_new_messages(messages_to_broadcast, is_first_broadcast: broadcast_count == 0)

      # Update the broadcast count and last timeline entry timestamp
      metadata_updates["broadcast_message_count"] = new_messages.length

      # Safe to write transcript here without a regression guard: this branch only
      # runs when new_messages.length > broadcast_count (otherwise messages_to_broadcast
      # is empty), i.e. the transcript grew. A shrink can only surface in the else
      # branch below, which is guarded.
      # Batch update: combine transcript, metadata, and last_timeline_entry_at in a single update
      with_db_retry do
        @session.reload
        @session.update!(
          transcript: transcript_content,
          metadata: (@session.metadata || {}).merge(metadata_updates),
          last_timeline_entry_at: Time.current
        )
      end

      # Run transcript hooks to extract data and update custom_metadata
      run_transcript_hooks(transcript_content, messages_to_broadcast)

      # Update the running loader to keep it at the bottom
      if @session.running?
        broadcast_running_loader
      end
    else
      # No new messages to broadcast, but the transcript file or metadata may
      # still have changed. Persist those — except never let session.transcript
      # shrink. A shorter transcript means the clone was recreated at a new path
      # and the runtime started a fresh file; since session.transcript is the only
      # durable record, overwriting it with the shorter file would permanently
      # destroy conversation history. Preserve the longer stored transcript.
      updates = {}

      if @session.transcript != transcript_content
        if Session.transcript_regression?(@session.transcript, transcript_content)
          # Log once per session so a recurring regression doesn't spam every poll.
          unless @session.metadata&.dig("transcript_regression_detected")
            @logger.warn(
              "Refused to overwrite stored transcript with a shorter one; preserving history (likely clone recreation)",
              stored_events: Session.transcript_line_count(@session.transcript),
              incoming_events: Session.transcript_line_count(transcript_content)
            )
            metadata_updates["transcript_regression_detected"] = true
          end
        else
          updates[:transcript] = transcript_content
        end
      end

      updates[:metadata] = (@session.metadata || {}).merge(metadata_updates) if metadata_updates.any?

      if updates.any?
        with_db_retry do
          @session.reload
          @session.update!(updates)
        end
      end
    end

    # Return true on successful poll
    true
  rescue => e
    Rails.logger.error "Error polling transcript for session #{@session.id}: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: @session.id, stage: "poll_and_broadcast" })
    # Return false to indicate polling failure
    false
  end

  private

  # Parse transcript content into raw event hashes via the runtime source.
  def parse_transcript_lines(transcript_content)
    @source.parse_events(transcript_content)
  end

  # Persist the runtime's own session id once it appears in the transcript.
  #
  # Some runtimes (Codex) generate their own session/thread UUID at spawn and
  # ignore the id Zimmer supplied; that generated UUID — emitted on the runtime's
  # session-metadata line — is the one resume must target. We read it from the
  # parsed events via the normalizer and store it when it changes. Gated on the
  # runtime's mints_own_session_id? trait so it is an outright no-op for runtimes
  # (Claude) whose stored session_id is already authoritative. Idempotent. Uses
  # update_column to persist just this field without disturbing the surrounding
  # transcript/metadata update flow.
  def capture_runtime_session_id!(raw_events)
    # Only runtimes that mint their own session id (Codex) learn it from the
    # transcript. Claude honors the Zimmer-supplied id, so its stored session_id is
    # authoritative and must never be rewritten from transcript content — see the
    # call-site comment and ClaudeTranscriptNormalizer#mints_own_session_id?.
    return unless @normalizer.mints_own_session_id?

    runtime_id = raw_events.filter_map { |event| @normalizer.extract_session_id(event) }.first
    return if runtime_id.blank?
    return if runtime_id == @session.session_id

    with_db_retry do
      @session.reload
      @session.update_column(:session_id, runtime_id)
    end
    @logger.info("Captured runtime session id from transcript", runtime_session_id: runtime_id)
  end

  # Broadcast new messages via BroadcastService
  # @param new_messages [Array] Messages to broadcast
  # @param is_first_broadcast [Boolean] Whether this is the first broadcast for the session
  def broadcast_new_messages(new_messages, is_first_broadcast: false)
    @logger.info("broadcast_new_messages called", message_count: new_messages.length)

    # Remove the empty timeline message placeholder only on the first broadcast
    # This ensures the "No activity yet" message is removed as soon as content arrives
    if is_first_broadcast
      @broadcast_service.remove_empty_timeline_message(@session)
    end

    new_messages.each_with_index do |message, index|
      message_type = message["type"]
      @logger.debug("Broadcasting message", index: index, type: message_type)

      # Delegate to BroadcastService for consistent error handling and retry logic
      @broadcast_service.timeline_message(@session, message)

      # Delay must be longer than SolidCable's polling_interval (100ms)
      sleep 0.15 if index < new_messages.length - 1
    end
  end

  # Get the transcript directory from the session.
  # Delegates the path computation to the runtime source; the working_directory
  # comes from the session metadata (set when the agent process is spawned).
  def get_transcript_directory
    # Use working_directory because the runtime creates the transcript directory
    # based on where the agent command is spawned from (chdir in Process.spawn)
    working_directory = @session.metadata&.dig("working_directory")

    unless working_directory
      Rails.logger.error "[TranscriptPollerService] No working_directory found in session metadata for session #{@session.id}"
      return nil
    end

    transcript_dir = @source.transcript_directory(working_directory: working_directory)
    Rails.logger.debug "[TranscriptPollerService] Calculated transcript directory: #{transcript_dir}"
    transcript_dir
  end

  # Broadcast the running loader via BroadcastService
  def broadcast_running_loader
    @logger.debug("Broadcasting running loader update")

    # Delegate to BroadcastService for consistent error handling and retry logic
    @broadcast_service.running_loader(@session)
  end

  # Find the main transcript file for the session.
  # Delegates to the runtime source.
  def find_main_transcript_file(transcript_dir)
    @source.find_main_transcript(transcript_directory: transcript_dir, session: @session)
  end

  # Poll and store subagent transcripts (agent-*.jsonl files)
  # These are created by nested Claude agents spawned via the Task tool
  # Returns array of updated subagents for broadcasting
  def poll_subagent_transcripts
    working_directory = @session.metadata&.dig("working_directory")
    agent_files = @source.discover_subagent_files(working_directory: working_directory, session_id: @session.session_id)
    return [] if agent_files.empty?

    updated_subagents = []

    agent_files.each do |file|
      agent_id = File.basename(file, ".jsonl")
      content = @file_system.read(file)
      message_count = content.lines.count { |l| l.strip.present? }

      with_db_retry do
        subagent = @session.subagent_transcripts.find_or_initialize_by(agent_id: agent_id)
        previous_message_count = subagent.message_count || 0

        subagent.transcript = content
        subagent.filename = File.basename(file)
        subagent.message_count = message_count

        # Track if this is a new or updated subagent
        is_new = subagent.new_record?
        has_new_messages = message_count > previous_message_count

        subagent.save!

        # Broadcast updates for new subagents or those with new messages
        if is_new || has_new_messages
          updated_subagents << subagent
        end
      end
    end

    # Broadcast updates for all modified subagents
    updated_subagents.each do |subagent|
      @broadcast_service.subagent_messages(@session, subagent)
    end

    updated_subagents
  rescue => e
    # Log but don't fail the main polling - subagent transcripts are supplementary
    Rails.logger.error "[TranscriptPollerService] Error polling subagent transcripts: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: @session.id, stage: "poll_subagent_transcripts" })
    []
  end

  # Update subagent metadata by parsing the main transcript for Task tool calls
  # This extracts tool_use_id, subagent_type, description, and completion stats
  def update_subagent_metadata_from_transcript(transcript_content)
    return unless transcript_content.present?

    messages = parse_transcript_lines(transcript_content)
    return if messages.empty?

    # Build a map of tool_use_id -> Task tool info from assistant messages
    task_tool_uses = extract_task_tool_uses(messages)

    # Process tool_results to link subagents and extract completion stats
    extract_subagent_links(messages, task_tool_uses)
  rescue => e
    Rails.logger.error "[TranscriptPollerService] Error updating subagent metadata: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: @session.id, stage: "update_subagent_metadata" })
  end

  # Extract Task tool_use blocks from assistant messages via the normalizer.
  # Returns: { tool_use_id => { subagent_type:, description: } }
  def extract_task_tool_uses(messages)
    task_tool_uses = {}

    messages.each do |message|
      @normalizer.extract_subagent_spawns(message).each do |spawn|
        task_tool_uses[spawn[:tool_use_id]] = {
          subagent_type: spawn[:subagent_type],
          description: spawn[:description]
        }
      end
    end

    task_tool_uses
  end

  # Run transcript hooks to extract data and update custom_metadata
  # Hooks are run in a fire-and-forget manner - errors don't affect transcript polling
  def run_transcript_hooks(transcript_content, new_messages)
    executor = TranscriptHooks::Executor.new(
      session: @session,
      transcript_content: transcript_content,
      new_messages: new_messages
    )

    results = executor.run_all
    failed = results.select { |r| !r[:success] }

    if failed.any?
      @logger.warn("Some transcript hooks failed", failed_hooks: failed.map { |r| r[:hook] })
    end
  rescue => e
    # Log but don't fail - hooks are non-critical
    Rails.logger.error "[TranscriptPollerService] Error running transcript hooks: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: @session.id, stage: "run_transcript_hooks" })
  end

  # Poll MCP server logs and update connection status in session custom_metadata
  # This detects MCP server connection failures early (before the transcript shows them).
  # `all_mcp_servers` is the union of user-configured and auto-injected servers, so
  # sessions with only injected servers (e.g. an Zimmer root that lists no MCP servers
  # of its own but has the agent-orchestrator MCP auto-injected for subagents) still
  # get their connection state tracked.
  def poll_mcp_logs(transcript_content = nil)
    return unless @session.all_mcp_servers.any?

    result = @mcp_status_detector.poll(transcript_content: transcript_content)
    return if result[:server_statuses].empty?

    # Broadcast new MCP log entries
    broadcast_mcp_logs(result[:logs])

    # Update session metadata with server statuses (may set should_fail_session)
    @mcp_status_detector.update_session_mcp_status(result[:server_statuses])
  rescue => e
    # Log but don't fail - MCP log polling is supplementary
    Rails.logger.error "[TranscriptPollerService] Error polling MCP logs: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: @session.id, stage: "poll_mcp_logs" })
  end

  # Broadcast MCP log entries to the timeline
  def broadcast_mcp_logs(logs)
    return if logs.empty?

    # Track which logs we've already broadcast
    broadcast_mcp_log_count = @session.metadata&.dig("broadcast_mcp_log_count") || 0
    new_logs = logs[broadcast_mcp_log_count..]
    return if new_logs.blank?

    new_logs.each do |log|
      # Format as a timeline message compatible with existing rendering
      mcp_message = {
        "type" => "mcp_log",
        "server_name" => log[:server_name],
        "level" => log[:level],
        "message" => log[:message],
        "timestamp" => log[:timestamp]
      }
      @broadcast_service.timeline_message(@session, mcp_message)
    end

    # Update broadcast count and last_timeline_entry_at
    # Updating last_timeline_entry_at here is critical because MCP activity indicates
    # the session is actively doing work (e.g., subagents making tool calls).
    # Without this, sessions with long-running subagents would be incorrectly
    # detected as "hung" by CleanupOrphanedSessionsJob after 15 minutes of no
    # transcript messages, even though MCP tools are being actively called.
    with_db_retry do
      @session.reload
      @session.update!(
        metadata: (@session.metadata || {}).merge("broadcast_mcp_log_count" => logs.length),
        last_timeline_entry_at: Time.current
      )
    end
  rescue => e
    Rails.logger.error "[TranscriptPollerService] Error broadcasting MCP logs: #{e.message}"
    ErrorReporter.report_exception(e, context: { session_id: @session.id, stage: "broadcast_mcp_logs" })
  end

  # Extract subagent links from tool_results (via the normalizer) and update
  # SubagentTranscript records.
  def extract_subagent_links(messages, task_tool_uses)
    messages.each do |message|
      @normalizer.extract_subagent_links(message).each do |link|
        agent_id = link[:agent_id]

        # Find the subagent transcript record
        # agent_id in transcript file is "agent-<id>" but toolUseResult has just "<id>"
        full_agent_id = agent_id.start_with?("agent-") ? agent_id : "agent-#{agent_id}"
        subagent = @session.subagent_transcripts.find_by(agent_id: full_agent_id)
        next unless subagent

        # Get Task tool info if available
        task_info = task_tool_uses[link[:tool_use_id]] || {}

        # Update subagent with metadata and broadcast accordion update
        with_db_retry do
          # Track if status changed (for broadcasting)
          previous_status = subagent.status

          subagent.update!(
            tool_use_id: link[:tool_use_id],
            subagent_type: task_info[:subagent_type],
            description: task_info[:description],
            status: link[:status] || "completed",
            duration_ms: link[:duration_ms],
            total_tokens: link[:total_tokens],
            tool_use_count: link[:tool_use_count]
          )

          # Broadcast accordion update when status or metadata changes
          if subagent.status != previous_status || subagent.saved_changes.any?
            @broadcast_service.subagent_accordion(@session, subagent)
          end
        end
      end
    end
  end

  # Parse job_started_at from session metadata for MCP log filtering
  # @param session [Session] The session to get job_started_at from
  # @return [Time, nil] The job start time, or nil if not set/parseable
  def job_started_at_from_metadata(session)
    job_started_at = session.metadata&.dig("job_started_at")
    return nil unless job_started_at

    Time.parse(job_started_at)
  rescue ArgumentError
    nil
  end

  # Check if any new messages are user messages that match the sent_message
  # and mark it for clearing if found. This ensures the sent_message is removed
  # from metadata once it's confirmed in the transcript.
  #
  # @param messages [Array] New messages from the transcript
  # @param metadata_updates [Hash] Hash to accumulate metadata changes
  def clear_sent_message_if_found(messages, metadata_updates)
    sent_message = @session.metadata&.dig("sent_message")
    return unless sent_message.present?

    # Look for a user message that matches the sent_message
    found = messages.any? do |message|
      message_data = message["message"] || message
      role = message_data["role"] || message["type"]

      next false unless role == "user"

      # Extract the content from the message
      content = message_data["content"]

      # Handle different content formats
      message_text = case content
      when String
        content
      when Array
        # Extract text from content blocks
        content.filter_map { |block| block["text"] if block["type"] == "text" }.join
      else
        nil
      end

      # Check if the message text matches the sent_message
      # Use exact match to avoid false positives (e.g., short common strings like "yes")
      # Slight whitespace differences are normalized by stripping
      next false unless message_text.present?

      message_text.strip == sent_message.strip
    end

    if found
      @logger.info("Clearing sent_message from metadata - message confirmed in transcript")
      metadata_updates["sent_message"] = nil
      metadata_updates["sent_message_at"] = nil
    end
  end
end
