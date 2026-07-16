# Service for executing Claude CLI commands
# Encapsulates all interactions with the claude CLI binary
#
# Supports two modes of operation:
# 1. Text-only prompts: Uses direct CLI arguments (for small prompts)
# 2. Prompts with images or large text: Uses stream-json input mode with -p flag
#
# When images are provided or the prompt exceeds LARGE_PROMPT_THRESHOLD, the adapter
# uses the stream-json format:
#   echo '{"type":"user","message":{...}}' | claude -p --input-format stream-json ...
#
# This prevents "Argument list too long" errors from the OS when spawning processes
# with very large command-line arguments.
#
# MCP Server Timeout:
#   When MCP servers are configured, the adapter sets MCP_TIMEOUT environment variable
#   to allow longer startup times for package installation. Default is 180000ms (3 min)
#   which is longer than Claude Code's default 30000ms (30s) to handle cold starts
#   when npm packages need to be downloaded.
#
class ClaudeCliAdapter
  include RuntimeCliAdapter
  include ClaudeSpawnEnv

  class ClaudeCliError < StandardError; end

  # Refuse to spawn without a working directory. Process.spawn would otherwise
  # reject a nil chdir deep inside the C call with "no implicit conversion of nil
  # into String", which tells an operator nothing about which argument was nil.
  #
  # A nil working_dir is always a caller bug, and it has two possible causes: the
  # session never established a clone (it died during its first spawn, before
  # metadata was written), or a caller failed to load the established one from
  # session metadata. The message names both — naming only the first sends an
  # operator hunting for a missing clone that may be sitting intact on disk.
  #
  # A class method so the test double enforces the identical contract: a double
  # that spawns happily with a nil working dir hides this class of bug from the
  # suite.
  def self.validate_working_dir!(working_dir)
    return unless working_dir.nil? || (working_dir.is_a?(String) && working_dir.strip.empty?)

    raise ClaudeCliError,
      "Cannot spawn Claude CLI: working directory is missing (got #{working_dir.inspect}). " \
      "Either the session never established a clone/working directory, or the caller did not " \
      "load session.metadata[\"working_directory\"] before spawning."
  end

  # Tools that Zimmer-spawned Claude Code sessions must never invoke.
  # Zimmer sessions run with --dangerously-skip-permissions, which bypasses
  # settings.json permission checks and makes PreToolUse hooks unreliable
  # (see anthropics/claude-code#20946). The --disallowedTools CLI flag is
  # the one enforcement mechanism that still applies in bypass mode.
  #
  # Monitor / ScheduleWakeup / Bash(sleep *) are Claude Code's in-process
  # async-wait primitives. They don't fit the Zimmer execution model — Zimmer
  # sessions should use the Zimmer-native wake_me_up_later /
  # wake_me_up_when_session_changes_state MCP tools for scheduled
  # resumption instead.
  #
  # Skill(schedule) blocks the `/schedule` skill that ships with the Claude
  # Code CLI. That skill creates scheduled remote agents and is geared
  # toward terminal-attached users who walk away from their machine — it
  # is non-functional inside a Zimmer session and was previously a frequent
  # mistake target despite the system-prompt directive against it. Zimmer has
  # its own trigger system + wake-me-up tools that serve the same intent.
  #
  # AskUserQuestion surfaces an interactive multiple-choice prompt to the
  # user. Zimmer sessions are autonomous — when an agent invokes this tool, it
  # stalls the session waiting on interactive input that doesn't fit the
  # Zimmer execution model (the same reason EnterPlanMode/ExitPlanMode are
  # forbidden via the system prompt). Zimmer's own guidance tells agents to
  # avoid clarifying questions and prioritize autonomy; blocking the tool
  # makes that enforceable instead of advisory.
  #
  # Note: ScheduleWakeup is also env-disabled via CLAUDE_CODE_DISABLE_CRON
  # (set in spawn_process/spawn_process_with_stdin). Listing it here too is
  # belt-and-suspenders — if the env var is ever dropped, the CLI flag still
  # blocks the tool.
  DISALLOWED_TOOLS = [ "Monitor", "ScheduleWakeup", "Bash(sleep *)", "Skill(schedule)", "AskUserQuestion" ].freeze

  # Default auto-compact window in tokens. A large window lets a big transcript
  # load fully before Claude Code compacts, avoiding compaction thrashing on
  # long-running sessions. Per-session overrides flow in via the
  # auto_compact_window kwarg on execute/resume.
  DEFAULT_AUTO_COMPACT_WINDOW = 1_000_000

  # Threshold for switching to stdin-based prompt delivery
  # When a prompt exceeds this size, we use stream-json input via stdin
  # instead of passing the prompt as a CLI argument.
  #
  # ARG_MAX on Linux is typically 2MB (getconf ARG_MAX), but this limit is shared
  # by command-line arguments AND environment variables. We use 100KB as a
  # conservative threshold to leave room for:
  # - Large environment variables (API keys, config)
  # - Other CLI arguments (session_id, mcp_config_path, etc.)
  # - Platform variation (some systems may have lower limits)
  LARGE_PROMPT_THRESHOLD = 100.kilobytes

  attr_accessor :process_manager, :file_system, :zimmer_session_id

  def initialize(logger: Rails.logger)
    @logger = logger
    @process_manager = SystemProcessManager.new
    @file_system = RealFileSystemAdapter.new
  end

  # Execute a new Claude CLI session
  #
  # @param prompt [String] The text prompt to send
  # @param session_id [String] UUID for the session
  # @param working_dir [String] Working directory for the process
  # @param mcp_config_path [String, nil] Path to MCP config file
  # @param images [Array<Hash>, nil] Array of image data hashes with :path, :media_type keys
  # @param append_system_prompt [String, nil] Additional system prompt to append to Claude's defaults
  # @param model [String, nil] Model to use (e.g., "opus", "sonnet")
  # @param dangerously_skip_permissions [Boolean] Skip permission checks
  # @param debug [Boolean] Enable debug mode
  # @param auto_compact_window [Integer] Token budget for CLAUDE_CODE_AUTO_COMPACT_WINDOW
  # @return [Hash] { pid: Integer, stderr_log_path: String }
  def execute(prompt:, session_id:, working_dir:, mcp_config_path: nil, images: nil,
              append_system_prompt: nil, model: nil, dangerously_skip_permissions: true, debug: false,
              auto_compact_window: DEFAULT_AUTO_COMPACT_WINDOW)
    # Use stdin-based delivery for images or large prompts to avoid ARG_MAX limits
    use_stdin = images.present? || large_prompt?(prompt)

    if use_stdin
      execute_with_stdin(
        prompt: prompt,
        session_id: session_id,
        working_dir: working_dir,
        mcp_config_path: mcp_config_path,
        images: images,
        append_system_prompt: append_system_prompt,
        model: model,
        dangerously_skip_permissions: dangerously_skip_permissions,
        debug: debug,
        auto_compact_window: auto_compact_window
      )
    else
      command = build_command(
        prompt: prompt,
        session_id: session_id,
        mcp_config_path: mcp_config_path,
        append_system_prompt: append_system_prompt,
        model: model,
        dangerously_skip_permissions: dangerously_skip_permissions,
        debug: debug
      )
      spawn_process(command, working_dir: working_dir, has_mcp: mcp_config_path.present?, auto_compact_window: auto_compact_window)
    end
  end

  # Resume an existing Claude CLI session
  #
  # @param session_id [String] UUID of the session to resume
  # @param working_dir [String] Working directory for the process
  # @param prompt [String, nil] Follow-up prompt to send
  # @param images [Array<Hash>, nil] Array of image data hashes with :path, :media_type keys
  # @param mcp_config_path [String, nil] Path to MCP config file (for setting MCP_TIMEOUT)
  # @param append_system_prompt [String, nil] Additional system prompt to append to Claude's defaults
  # @param model [String, nil] Model to use (e.g., "opus", "sonnet")
  # @param dangerously_skip_permissions [Boolean] Skip permission checks
  # @param debug [Boolean] Enable debug mode
  # @param auto_compact_window [Integer] Token budget for CLAUDE_CODE_AUTO_COMPACT_WINDOW
  # @return [Hash] { pid: Integer, stderr_log_path: String }
  def resume(session_id:, working_dir:, prompt: nil, images: nil, mcp_config_path: nil,
             append_system_prompt: nil, model: nil, dangerously_skip_permissions: true, debug: false,
             auto_compact_window: DEFAULT_AUTO_COMPACT_WINDOW)
    # Use stdin-based delivery for images or large prompts to avoid ARG_MAX limits
    use_stdin = images.present? || large_prompt?(prompt)

    if use_stdin
      resume_with_stdin(
        session_id: session_id,
        working_dir: working_dir,
        prompt: prompt,
        images: images,
        mcp_config_path: mcp_config_path,
        append_system_prompt: append_system_prompt,
        model: model,
        dangerously_skip_permissions: dangerously_skip_permissions,
        debug: debug,
        auto_compact_window: auto_compact_window
      )
    else
      command = build_resume_command(
        session_id: session_id,
        prompt: prompt,
        mcp_config_path: mcp_config_path,
        append_system_prompt: append_system_prompt,
        model: model,
        dangerously_skip_permissions: dangerously_skip_permissions,
        debug: debug
      )
      spawn_process(command, working_dir: working_dir, has_mcp: mcp_config_path.present?, auto_compact_window: auto_compact_window)
    end
  end

  # The CLI binary this adapter spawns. Part of the RuntimeCliAdapter contract.
  def binary_name
    "claude"
  end

  # A concise, human-readable summary of the command this adapter spawns, for
  # operator-facing session logs. Part of the RuntimeCliAdapter contract — each
  # runtime owns its own representation so callers never re-fabricate a
  # binary+flags string (which is how Codex sessions ended up logging "claude").
  # The verbose --append-system-prompt value is omitted and the prompt is
  # truncated; this is a debugging summary, not an exact reproduction.
  def command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false)
    parts = [ binary_name, "--dangerously-skip-permissions" ]
    if resume
      parts << "--resume" << session_id
    else
      parts << "--mcp-config" << mcp_config_path if mcp_config_path.present?
      parts << "--session-id" << session_id
    end
    parts << "--" << prompt[0..100] if prompt.present?
    parts.join(" ")
  end

  # Tools Zimmer-spawned Claude Code sessions must never invoke. Part of the
  # RuntimeCliAdapter contract; see DISALLOWED_TOOLS for rationale.
  def disallowed_tools
    DISALLOWED_TOOLS
  end

  # Build the Claude-specific exit classifier consumed by ProcessLifecycleManager.
  # Part of the RuntimeCliAdapter contract.
  def retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    ClaudeRetryStrategy.new(
      cli_adapter: self,
      session: session,
      file_system: file_system,
      process_manager: process_manager,
      rate_limit_tracker: rate_limit_tracker,
      logger: logger
    )
  end

  private

  # Check if a prompt is large enough to require stdin-based delivery
  #
  # @param prompt [String, nil] The prompt to check
  # @return [Boolean] True if prompt exceeds LARGE_PROMPT_THRESHOLD
  def large_prompt?(prompt)
    return false if prompt.blank?
    prompt.bytesize > LARGE_PROMPT_THRESHOLD
  end

  # Execute using stream-json input mode (for images or large prompts)
  #
  # This method uses the -p (print) mode with stream-json input/output to send
  # the prompt to Claude. The process receives the message via stdin pipe.
  #
  # IMPORTANT: This uses -p mode which is single-turn and exits after response.
  # For multi-turn sessions, the session_id persists the conversation.
  def execute_with_stdin(prompt:, session_id:, working_dir:, mcp_config_path:, images:,
                         append_system_prompt:, model:, dangerously_skip_permissions:, debug:,
                         auto_compact_window:)
    command = build_stream_json_command(
      session_id: session_id,
      mcp_config_path: mcp_config_path,
      append_system_prompt: append_system_prompt,
      model: model,
      dangerously_skip_permissions: dangerously_skip_permissions,
      debug: debug
    )

    message_json = build_message_json(prompt: prompt, images: images)
    spawn_process_with_stdin(command, working_dir: working_dir, stdin_content: message_json, has_mcp: mcp_config_path.present?, auto_compact_window: auto_compact_window)
  end

  # Resume using stream-json input mode (for images or large prompts)
  def resume_with_stdin(session_id:, working_dir:, prompt:, images:, mcp_config_path:,
                        append_system_prompt:, model:, dangerously_skip_permissions:, debug:,
                        auto_compact_window:)
    command = build_stream_json_resume_command(
      session_id: session_id,
      mcp_config_path: mcp_config_path,
      append_system_prompt: append_system_prompt,
      model: model,
      dangerously_skip_permissions: dangerously_skip_permissions,
      debug: debug
    )

    message_json = build_message_json(prompt: prompt, images: images)
    spawn_process_with_stdin(command, working_dir: working_dir, stdin_content: message_json, has_mcp: mcp_config_path.present?, auto_compact_window: auto_compact_window)
  end

  # Build command for stream-json mode (new session)
  def build_stream_json_command(session_id:, mcp_config_path:, append_system_prompt:, model: nil, dangerously_skip_permissions:, debug:)
    cmd = [ "claude", "-p" ]
    cmd << "--dangerously-skip-permissions" if dangerously_skip_permissions
    append_disallowed_tools(cmd)
    cmd << "--debug" if debug
    cmd << "--model" << model if model.present?
    cmd << "--append-system-prompt" << append_system_prompt if append_system_prompt.present?
    cmd << "--input-format" << "stream-json"
    cmd << "--output-format" << "stream-json"
    cmd << "--verbose"
    cmd << "--session-id" << session_id
    cmd << "--mcp-config" << mcp_config_path if mcp_config_path
    cmd
  end

  # Build command for stream-json resume mode
  def build_stream_json_resume_command(session_id:, mcp_config_path:, append_system_prompt:, model: nil, dangerously_skip_permissions:, debug:)
    cmd = [ "claude", "-p" ]
    cmd << "--dangerously-skip-permissions" if dangerously_skip_permissions
    append_disallowed_tools(cmd)
    cmd << "--debug" if debug
    cmd << "--model" << model if model.present?
    cmd << "--append-system-prompt" << append_system_prompt if append_system_prompt.present?
    cmd << "--mcp-config" << mcp_config_path if mcp_config_path
    cmd << "--input-format" << "stream-json"
    cmd << "--output-format" << "stream-json"
    cmd << "--verbose"
    cmd << "--resume" << session_id
    cmd
  end

  # Build the JSON message for stream-json mode
  #
  # Format: {"type":"user","message":{"role":"user","content":[...]}}
  #
  # @param prompt [String] The text prompt
  # @param images [Array<Hash>, nil] Optional array of { path:, media_type: } hashes
  # @return [String] JSON string to send via stdin
  def build_message_json(prompt:, images:)
    content = []

    # Add images first, then text (Claude API convention)
    if images.present?
      images.each do |image|
        image_data = load_image_as_base64(image[:path])
        content << {
          type: "image",
          source: {
            type: "base64",
            media_type: image[:media_type],
            data: image_data
          }
        }
      end
    end

    # Add text prompt
    content << {
      type: "text",
      text: prompt || ""
    }

    message = {
      type: "user",
      message: {
        role: "user",
        content: content
      }
    }

    message.to_json
  end

  # Load image file and encode as base64
  #
  # Defense-in-depth: validates path is within the expected image storage directory
  # even though callers should already validate via ImageStorageService.exists?
  def load_image_as_base64(path)
    # Validate path is within expected image storage directory (defense-in-depth).
    # Resolve the storage root at call time so this tracks ImageStorageService's
    # durable, cross-container base rather than a hardcoded /tmp path.
    expected_prefix = File.join(ImageStorageService.storage_root, "")
    resolved_path = File.expand_path(path)
    unless resolved_path.start_with?(expected_prefix)
      raise ClaudeCliError, "Invalid image path: must be within #{expected_prefix}"
    end

    # Use binread for binary image data
    content = @file_system.binread(path)
    Base64.strict_encode64(content)
  end

  # Guard the spawn entrypoints against nil/blank arguments that Process.spawn
  # would otherwise reject deep inside the C call with the cryptic
  # "no implicit conversion of nil into String" — a message that gives an
  # operator no idea which argument was nil or why.
  #
  # A nil element in the command means a required value (session_id, model,
  # prompt, …) was nil. Fail fast naming the real cause.
  def validate_spawn_args!(command, working_dir)
    self.class.validate_working_dir!(working_dir)

    nil_index = command.index(nil)
    unless nil_index.nil?
      raise ClaudeCliError,
        "Cannot spawn Claude CLI: command contains a nil argument at position #{nil_index} " \
        "(#{command.inspect}). A required value (e.g. session_id, model, or prompt) was nil."
    end
  end

  # Spawn process with stdin input (for stream-json mode)
  #
  # CRITICAL: stdin MUST be delivered through a pipe, not a regular file.
  # Claude CLI's `--input-format stream-json` reader only consumes stdin when it
  # is a pipe (a non-seekable stream). When stdin is a regular file, the CLI
  # silently reads nothing, processes no message, and exits 0 — which means an
  # image/large-prompt follow-up gets dropped with no error (this was the bug
  # where a follow-up with an image attachment never reached the agent). We feed
  # the payload via an IO.pipe and write it from a background thread so the
  # caller never blocks on the OS pipe buffer (~64KB) for large base64 payloads.
  def spawn_process_with_stdin(command, working_dir:, stdin_content:, has_mcp: false, auto_compact_window: DEFAULT_AUTO_COMPACT_WINDOW)
    validate_spawn_args!(command, working_dir)
    @logger.info "Spawning Claude CLI with stream-json: #{command.join(' ')}"

    stderr_log_path = File.join(working_dir, "claude_stderr.log")

    # For mock testing, handle stderr differently
    stderr_file = if !@file_system.is_a?(RealFileSystemAdapter)
      @file_system.write(stderr_log_path, "")
      File.open(File::NULL, "w")
    else
      File.open(stderr_log_path, "w")
    end

    # Deliver stdin through a pipe (NOT a regular file — see method comment).
    # The child reads from `stdin_reader`; we write the payload to `stdin_writer`
    # on a background thread and close it to signal EOF.
    stdin_reader, stdin_writer = IO.pipe

    env_vars = build_claude_spawn_env(working_dir: working_dir, has_mcp: has_mcp, auto_compact_window: auto_compact_window)

    pid = @process_manager.spawn(
      env_vars,
      *command,
      chdir: working_dir,
      pgroup: true,
      in: stdin_reader,
      out: File::NULL,
      err: stderr_file
    )

    # The child holds its own dup of the read end; close ours so the pipe has a
    # single reader and the child sees EOF once the writer closes.
    stdin_reader.close
    stderr_file.close

    # Write the payload from a background thread. Writing inline would block the
    # caller once the payload exceeds the OS pipe buffer (~64KB) until the child
    # drains it — large base64 image payloads routinely exceed that. Errno::EPIPE
    # (child exited early) and IOError (writer already closed) are expected and
    # benign here.
    Thread.new do
      stdin_writer.write(stdin_content)
    rescue Errno::EPIPE, IOError
      # Child closed stdin before consuming everything — nothing to do.
    ensure
      stdin_writer.close unless stdin_writer.closed?
    end

    { pid: pid, stderr_log_path: stderr_log_path }
  rescue => e
    stdin_reader&.close unless stdin_reader&.closed?
    stdin_writer&.close unless stdin_writer&.closed?
    stderr_file&.close
    raise ClaudeCliError, "Failed to spawn Claude CLI via stdin: #{e.message}"
  end

  def build_command(prompt:, session_id:, mcp_config_path:, append_system_prompt:, model: nil, dangerously_skip_permissions:, debug:)
    cmd = [ "claude" ]
    cmd << "--dangerously-skip-permissions" if dangerously_skip_permissions
    append_disallowed_tools(cmd)
    cmd << "--debug" if debug
    cmd << "--model" << model if model.present?
    cmd << "--append-system-prompt" << append_system_prompt if append_system_prompt.present?
    cmd << "--mcp-config" << mcp_config_path if mcp_config_path
    cmd << "--session-id" << session_id
    # Use "--" to signal end of options, so prompts starting with dashes
    # (e.g., "---- forked conversation") are not interpreted as unknown flags
    cmd << "--" << prompt
    cmd
  end

  def build_resume_command(session_id:, prompt:, mcp_config_path:, append_system_prompt:, model: nil, dangerously_skip_permissions:, debug:)
    cmd = [ "claude" ]
    cmd << "--dangerously-skip-permissions" if dangerously_skip_permissions
    append_disallowed_tools(cmd)
    cmd << "--debug" if debug
    cmd << "--model" << model if model.present?
    cmd << "--append-system-prompt" << append_system_prompt if append_system_prompt.present?
    cmd << "--mcp-config" << mcp_config_path if mcp_config_path
    cmd << "--resume" << session_id
    # Use "--" to signal end of options, so prompts starting with dashes
    # (e.g., "---- forked conversation") are not interpreted as unknown flags
    cmd << "--" << prompt if prompt.present?
    cmd
  end

  # Append --disallowedTools with the DISALLOWED_TOOLS list, unconditionally.
  # See DISALLOWED_TOOLS for rationale.
  def append_disallowed_tools(cmd)
    cmd << "--disallowedTools"
    cmd.concat(DISALLOWED_TOOLS)
  end

  def spawn_process(command, working_dir:, has_mcp: false, auto_compact_window: DEFAULT_AUTO_COMPACT_WINDOW)
    validate_spawn_args!(command, working_dir)
    @logger.info "Spawning Claude CLI: #{command.join(' ')}"

    stderr_log_path = File.join(working_dir, "claude_stderr.log")

    # For mock testing, handle stderr differently
    # Check if we're using a mock file system by checking if it's NOT a RealFileSystemAdapter
    stderr_file = if !@file_system.is_a?(RealFileSystemAdapter)
      # For mock, create an empty file in the mock file system and use /dev/null for actual redirection
      @file_system.write(stderr_log_path, "")
      File.open(File::NULL, "w")
    else
      # For real execution, use actual file
      File.open(stderr_log_path, "w")
    end

    env_vars = build_claude_spawn_env(working_dir: working_dir, has_mcp: has_mcp, auto_compact_window: auto_compact_window)

    pid = @process_manager.spawn(
      env_vars,
      *command,
      chdir: working_dir,
      pgroup: true,
      in: File::NULL,
      out: File::NULL,
      err: stderr_file
    )

    stderr_file.close

    { pid: pid, stderr_log_path: stderr_log_path }
  rescue => e
    stderr_file&.close
    raise ClaudeCliError, "Failed to spawn Claude CLI: #{e.message}"
  end
end
