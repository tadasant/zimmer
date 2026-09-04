# frozen_string_literal: true

require "open3"
require "timeout"

# PiRuntimeAdapter — the RuntimeCliAdapter implementation for the Pi coding
# agent (`pi`). It builds the command, prepares the environment, and spawns the
# process, returning the pid plus the stderr log path the monitoring loop tails.
# ProcessLifecycleManager depends only on the RuntimeCliAdapter contract, so it
# drives this adapter exactly as it drives the Claude and Codex ones.
#
# == Pi CLI surface (pi 0.84.x, `pi --help`) ==
#
#   pi -p --mode json --session-dir <dir> --session-id <uuid> \
#      --model <provider/id> --append-system-prompt <file> \
#      --approve -e <ext> ... -- <prompt>
#
# - `-p/--print` is Pi's non-interactive mode: process the prompt and exit.
# - `--mode json` streams session events as JSONL on stdout. Zimmer discards
#   stdout (out: NULL) and reads Pi's own session JSONL file instead — the single
#   source of truth, exactly as the Claude and Codex transcript flows work.
# - `--session-dir <dir>` chooses where the session JSONL lives. Zimmer points it
#   at a per-clone directory (PiTranscriptSource.session_directory) rather than
#   Pi's host-global `~/.pi/agent/sessions` tree. See the note on collisions below.
# - `--session-id <uuid>` uses an EXACT session id, "creating it if missing". This
#   is the flag Codex lacks: Pi accepts a Zimmer-minted id for both the first turn
#   and every resume, so Zimmer never has to capture a runtime-generated id and
#   PiTranscriptNormalizer#mints_own_session_id? is false.
# - `--model <pattern>` accepts a bare id or a `provider/id` pair. ModelCatalog's
#   Pi entries are provider-qualified, so no separate `--provider` flag is needed.
# - `--append-system-prompt <text|file>` appends text OR a file's contents. Zimmer
#   passes a FILE PATH: the orchestrator prompt is many kilobytes and putting it in
#   argv risks E2BIG on a long prompt, which would fail the spawn outright.
# - `--approve` trusts project-local files for the run. Zimmer writes `.pi/skills/`
#   (via `air prepare pi`) and `.mcp.json` into the clone itself; without this flag
#   Pi treats them as untrusted third-party content and, having no TTY in `-p` mode
#   to ask about them, would silently ignore everything Zimmer just prepared.
# - `-e <path>` loads an extension file. Pi has no MCP, hooks, or plugins of its
#   own; every one of those arrives as an extension (see PiExtensions). The hook
#   and plugin extensions are configured through the environment rather than a
#   flag — see #apply_air_bridge_env.
# - `@<path>` attaches a file (including images) to the message.
# - `--` ends option parsing so a prompt beginning with a dash is not read as a flag.
#
# == Differences from CodexRuntimeAdapter ==
#
# - Session id: Zimmer's id IS Pi's id (`--session-id`), so `#execute` and
#   `#resume` are nearly the same command. Resume is not a distinct subcommand —
#   re-running with the same `--session-id` continues the existing session tree.
# - Transcript location: per-clone, not a shared host-global tree. Two concurrent
#   Codex sessions write into one rollout directory, which is why
#   CodexTranscriptSource needs a cwd-matching fallback to avoid reading another
#   session's transcript. Pi sessions cannot collide, because the clone path is
#   unique per session and the session directory lives inside it.
# - MCP config: Pi reads `.mcp.json` from the working directory via the
#   pi-mcp-adapter extension, so `mcp_config_path` IS meaningful here (unlike
#   Codex, which ignores it) — but it is still not a CLI flag, because the
#   adapter discovers the file by convention. PiMcpConfigPostProcessor writes it.
# - System prompt: delivered by flag, not by file convention. Codex has no
#   `--append-system-prompt` and so must write AGENTS.md; Pi has the flag, so the
#   prompt goes through a spawn-scoped file that Pi reads and Zimmer owns. Pi
#   ALSO reads AGENTS.md/CLAUDE.md from the working directory on its own, which is
#   why PiRuntimePromptContribution#delivered_via_file? is false: delivering the
#   orchestrator prompt twice would double it in the model's context.
# - disallowed_tools is empty: Zimmer runs Pi with its full built-in tool set
#   inside an already-isolated container, the same posture as Codex.
class PiRuntimeAdapter
  include RuntimeCliAdapter
  include CliSpawnEnv

  class PiCliError < StandardError; end

  # The stderr log the Pi process writes inside its working directory. Part of
  # the RuntimeCliAdapter contract — every caller that rebuilds a stderr path
  # (Session#stderr_log_path, PiRetryStrategy) reads it from here.
  STDERR_LOG_FILENAME = "pi_stderr.log"

  # Where the orchestrator system prompt is staged for `--append-system-prompt`.
  # Kept inside the clone alongside pi_stderr.log, and rewritten on every spawn
  # so a resumed turn never appends a stale prompt.
  SYSTEM_PROMPT_FILENAME = "pi_system_prompt.md"

  def self.stderr_log_filename
    STDERR_LOG_FILENAME
  end

  # Keep the runtime's own error type for the shared spawn guards
  # (RuntimeCliAdapter::ClassMethods#validate_working_dir!).
  def self.spawn_error_class
    PiCliError
  end

  def self.cli_label
    "Pi CLI"
  end

  attr_accessor :process_manager, :file_system, :zimmer_session_id

  def initialize(logger: Rails.logger)
    @logger = logger
    @process_manager = SystemProcessManager.new
    @file_system = RealFileSystemAdapter.new
  end

  # Execute a new Pi session.
  #
  # @param prompt [String] the text prompt to send
  # @param session_id [String] Zimmer session UUID — passed straight to Pi as
  #   `--session-id`, which creates the session with that exact id
  # @param working_dir [String] working directory for the process
  # @param mcp_config_path [String, nil] accepted for contract symmetry. Pi's
  #   MCP support comes from the pi-mcp-adapter extension, which discovers
  #   `.mcp.json` in the working directory by convention rather than by flag.
  # @param images [Array<Hash>, nil] image hashes with a :path key
  # @param append_system_prompt [String, nil] staged to a file and passed with
  #   `--append-system-prompt`
  # @param model [String, nil] `provider/id` pattern (e.g. "openrouter/anthropic/claude-opus-4.6")
  # @param auto_compact_window [Integer, nil] accepted for contract symmetry with
  #   ClaudeCliAdapter but unused: auto-compaction is driven by the
  #   CLAUDE_CODE_AUTO_COMPACT_WINDOW env var, which Pi has no analog for (Pi
  #   compacts on its own schedule). ProcessLifecycleManager passes it uniformly
  #   to whichever adapter is selected, so the kwarg must exist here.
  # @return [Hash] { pid: Integer, stderr_log_path: String }
  def execute(prompt:, session_id:, working_dir:, mcp_config_path: nil, images: nil,
              append_system_prompt: nil, model: nil, auto_compact_window: nil)
    # Before anything joins onto working_dir — the session dir, the staged prompt
    # file and the stderr log all do, so the guard has to run here rather than at
    # spawn time to keep its message actionable.
    self.class.validate_working_dir!(working_dir)

    command = build_command(
      prompt: prompt,
      session_id: session_id,
      working_dir: working_dir,
      images: images,
      append_system_prompt: append_system_prompt,
      model: model
    )
    spawn_process(command, working_dir: working_dir)
  end

  # Resume an existing Pi session with an optional follow-up prompt.
  #
  # Pi has no `resume` subcommand: re-invoking with the same `--session-id`
  # continues that session's entry tree from its current leaf. So resume differs
  # from execute only in tolerating a blank prompt.
  #
  # @param session_id [String] the Zimmer/Pi session UUID to continue
  # @param working_dir [String] working directory for the process
  # @param prompt [String, nil] follow-up prompt to send
  # @param images [Array<Hash>, nil] image hashes with a :path key
  # @param mcp_config_path [String, nil] see #execute
  # @param append_system_prompt [String, nil] see #execute
  # @param model [String, nil] see #execute
  # @param auto_compact_window [Integer, nil] see #execute — accepted, unused
  # @return [Hash] { pid: Integer, stderr_log_path: String }
  def resume(session_id:, working_dir:, prompt: nil, images: nil, mcp_config_path: nil,
             append_system_prompt: nil, model: nil, auto_compact_window: nil)
    self.class.validate_working_dir!(working_dir)

    command = build_command(
      prompt: prompt,
      session_id: session_id,
      working_dir: working_dir,
      images: images,
      append_system_prompt: append_system_prompt,
      model: model
    )
    spawn_process(command, working_dir: working_dir)
  end

  # The CLI binary this adapter spawns. Part of the RuntimeCliAdapter contract.
  def binary_name
    "pi"
  end

  # The installed `pi --version`, or nil when the binary is missing or unreadable.
  def installed_cli_version
    stdout, _stderr, status = Timeout.timeout(10) do
      Open3.capture3(binary_name, "--version")
    end
    return nil unless SubprocessStatus.success?(status)

    match = stdout.to_s.match(/(\d+\.\d+\.\d+)/)
    match ? Gem::Version.new(match[1]) : nil
  rescue Errno::ENOENT, Errno::EACCES, Timeout::Error, ArgumentError
    nil
  end

  # A concise, human-readable summary of the spawned command, for operator-facing
  # session logs. Part of the RuntimeCliAdapter contract; must start with
  # binary_name. The prompt is truncated since this is a debugging summary, not
  # an exact reproduction.
  def command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false)
    parts = [ binary_name, "-p", "--mode", "json" ]
    parts << "--session-id" << session_id.to_s if session_id.present?
    parts << prompt[0..100] if prompt.present?
    parts.join(" ")
  end

  # Build the Pi-specific exit classifier consumed by ProcessLifecycleManager.
  # Part of the RuntimeCliAdapter contract.
  def retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    PiRetryStrategy.new(
      cli_adapter: self,
      session: session,
      file_system: file_system,
      process_manager: process_manager,
      rate_limit_tracker: rate_limit_tracker,
      logger: logger
    )
  end

  private

  # Build the `pi -p` command. One builder serves both execute and resume,
  # because `--session-id` is what distinguishes "start" from "continue" and it
  # is present either way.
  def build_command(prompt:, session_id:, working_dir:, images:, append_system_prompt:, model:)
    cmd = [ binary_name, "-p", "--mode", "json", "--approve" ]
    cmd << "--session-dir" << PiTranscriptSource.session_directory(working_directory: working_dir)
    cmd << "--session-id" << session_id.to_s if session_id.present?
    cmd << "--model" << model if model.present?

    prompt_file = stage_system_prompt(working_dir, append_system_prompt)
    cmd << "--append-system-prompt" << prompt_file if prompt_file

    PiExtensions.resolved_paths(file_system: @file_system).each { |path| cmd << "-e" << path }

    # Everything after `--` is message content, so a prompt starting with a dash
    # cannot be mistaken for a flag.
    cmd << "--"
    append_images(cmd, images)
    cmd << prompt if prompt.present?
    cmd
  end

  # Attach each image as an `@<path>` message argument, which is how Pi takes
  # file/image attachments (there is no `-i` flag as in Codex).
  def append_images(cmd, images)
    return unless images.present?

    images.each do |image|
      path = image[:path]
      cmd << "@#{path}" if path.present?
    end
  end

  # Stage the orchestrator system prompt to a file and return its path, or nil
  # when there is no prompt to append.
  #
  # A file rather than an inline argument: the orchestrator prompt runs to many
  # kilobytes, and Linux caps a single argv entry at MAX_ARG_STRLEN (128 KiB).
  # Passing it inline would make a long prompt fail the spawn with E2BIG instead
  # of running, so the file form is the one that always works.
  #
  # Rewritten on every spawn so a resumed turn appends the current prompt rather
  # than one staged for an earlier turn.
  def stage_system_prompt(working_dir, append_system_prompt)
    return nil if append_system_prompt.blank?

    path = File.join(working_dir, SYSTEM_PROMPT_FILENAME)
    @file_system.write(path, append_system_prompt)
    path
  end

  # Spawn the Pi process. Mirrors CodexRuntimeAdapter#spawn_process: stderr is
  # redirected to pi_stderr.log for the monitoring loop to tail, the process gets
  # its own group (pgroup: true) so the whole tree can be terminated, and
  # stdin/stdout are detached (the transcript pipeline reads Pi's session JSONL
  # rather than stdout).
  def spawn_process(command, working_dir:)
    self.class.validate_working_dir!(working_dir)

    @logger.info "Spawning Pi CLI: #{command.join(' ')}"

    stderr_log_path = self.class.stderr_log_path(working_dir)

    # Pi refuses to write a session file into a directory that does not exist,
    # and `--session-dir` points inside the clone, so create it before spawning.
    @file_system.mkdir_p(PiTranscriptSource.session_directory(working_directory: working_dir))

    # For mock testing, create the file in the mock file system and redirect the
    # real process's stderr to /dev/null; otherwise open the real log file.
    stderr_file = if !@file_system.is_a?(RealFileSystemAdapter)
      @file_system.write(stderr_log_path, "")
      File.open(File::NULL, "w")
    else
      File.open(stderr_log_path, "w")
    end

    env_vars = load_env_file(working_dir)
    env_vars = clear_inherited_env_vars(env_vars)
    env_vars = ensure_pi_home(env_vars)
    env_vars = quiet_pi_startup(env_vars)
    env_vars = apply_air_bridge_env(env_vars, working_dir)
    # Export the durable per-session scratch dir (AO_SESSION_SCRATCH_DIR) so
    # agents persist cross-step state on the durable volume instead of ephemeral /tmp.
    env_vars = apply_session_scratch_dir(env_vars)
    # Point the ssh-* MCP servers (and the plain ssh/git CLIs) at the operator SSH key.
    env_vars = apply_operator_ssh_key(env_vars)
    # Tell MCP servers where to send approval requests (and who is asking).
    env_vars = apply_elicitation_env(env_vars)

    pid = @process_manager.spawn(
      env_vars,
      *apply_session_memory_cgroup(command),
      chdir: working_dir,
      pgroup: true,
      in: File::NULL,
      out: File::NULL,
      err: stderr_file
    )

    stderr_file.close

    { pid: pid, stderr_log_path: stderr_log_path }
  rescue PiCliError
    # Already ours and already specific (the working-dir guard raises this).
    # Re-wrapping would bury its actionable message under a generic prefix.
    stderr_file&.close
    raise
  rescue => e
    stderr_file&.close
    raise PiCliError, "Failed to spawn Pi CLI: #{e.message}"
  end

  # Explicitly export PI_CODING_AGENT_DIR so the spawned `pi` resolves its
  # credentials (auth.json) and custom provider declarations (models.json) from
  # the same directory PiHome reports. Without this the child could fall back to
  # a home directory on the ephemeral overlay filesystem, where credentials are
  # wiped on container restart and every turn would fail unauthenticated. A value
  # provided via the session .env takes precedence.
  def ensure_pi_home(env_vars)
    return env_vars if env_vars["PI_CODING_AGENT_DIR"].present?

    env_vars.merge("PI_CODING_AGENT_DIR" => PiHome.path)
  end

  # Point Pi's hook and plugin extensions at the AIR config PiAirBridge generated
  # for this session, rather than letting them discover one.
  #
  # Both extensions look for `./air.json` and then `./.air/air.json` relative to
  # the working directory when their override variable is unset — and the working
  # directory is a clone of whatever repository the session works on. `air.json` at
  # a repo root is a normal thing for a repo to have (this one has one), so
  # discovery would let a cloned repository decide which hooks run in a Zimmer
  # session. Naming Zimmer's own generated files closes that, and makes the active
  # hook set exactly the session's selection.
  #
  # Values from the session .env still take precedence, and PiAirBridge.spawn_env
  # omits a variable whose file is not on disk, so a session prepared without the
  # bridge falls back to Pi's own behavior instead of pointing at nothing.
  def apply_air_bridge_env(env_vars, working_dir)
    bridge_env = PiAirBridge.spawn_env(working_dir, file_system: @file_system)
    bridge_env.merge(env_vars.select { |key, value| !bridge_env.key?(key) || value.present? })
  end

  # Suppress the two Pi startup network calls that can only cost a Zimmer session
  # time: the pi.dev version check and the install/update telemetry ping.
  #
  # Both are pure startup latency for an unattended session that will never act
  # on a "new version available" notice, and both are failure modes with no
  # upside — a session spawned while egress is degraded would wait on them before
  # reaching the prompt. Zimmer pins the Pi version in the base image, so the
  # check has nothing to tell it.
  #
  # Deliberately NOT `PI_OFFLINE`, which is the bigger hammer covering "all
  # startup network operations". That includes Pi's provider model-catalog
  # refresh, and a stale catalog is how a valid ModelCatalog id stops resolving —
  # the one network call at startup that a session actually depends on. Values
  # from the session .env take precedence.
  def quiet_pi_startup(env_vars)
    defaults = { "PI_SKIP_VERSION_CHECK" => "1", "PI_TELEMETRY" => "0" }
    # `select(&:present?)` on the session's values, not `reject` on the defaults:
    # the merge already lets any present session value win, so rejecting on the
    # defaults side is a no-op. What it must NOT do is let a BLANK session value
    # (`PI_TELEMETRY=` in a .env) override the default with an empty string,
    # which is how the flag would silently stop meaning anything.
    defaults.merge(env_vars.select { |key, value| !defaults.key?(key) || value.present? })
  end
end
