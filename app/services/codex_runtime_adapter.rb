# frozen_string_literal: true

# CodexRuntimeAdapter — the RuntimeCliAdapter implementation for OpenAI's Codex
# CLI (`codex`). It is the Codex counterpart to ClaudeCliAdapter: it builds the
# command, prepares the environment, and spawns the process, returning the pid
# plus the stderr log path the monitoring loop tails. ProcessLifecycleManager
# depends only on the RuntimeCliAdapter contract, so it drives this adapter the
# same way it drives the Claude one.
#
# == Codex CLI surface (see https://developers.openai.com/codex/cli) ==
#
#   codex exec --json --dangerously-bypass-approvals-and-sandbox --cd <dir> \
#     -m <model> --output-last-message <path> "<prompt>"
#
# - `exec` is Codex's non-interactive ("print") mode.
# - `--json` streams JSONL events to stdout (thread/turn/tool-call/message/usage),
#   the closest analog to Claude's `--output-format stream-json`. We discard
#   stdout (out: NULL) and let the transcript pipeline read Codex's own rollout
#   JSONL file (~/.codex/sessions/YYYY/MM/DD/rollout-*-<uuid>.jsonl) — the single
#   source of truth, mirroring how the Claude transcript flow works. Transcript
#   reading itself is #3779.
# - `--dangerously-bypass-approvals-and-sandbox` skips all approval prompts AND
#   disables Codex's own sandbox. This is the Codex analog to Claude's
#   `--dangerously-skip-permissions`. We must NOT use `--full-auto` here:
#   `--full-auto` selects the `workspace-write` sandbox, which Codex enforces via
#   bubblewrap (bwrap). AO runs every session inside an already-isolated,
#   externally-sandboxed container where the kernel disallows unprivileged user
#   namespaces, so bwrap aborts ("No permissions to create a new namespace") and
#   EVERY model-issued shell command fails before executing — the agent can do
#   nothing. The Codex docs explicitly intend this flag for "environments that are
#   externally sandboxed", which is exactly AO's model (#3884).
# - `--cd/-C <dir>` sets the working directory. NOTE: only `codex exec` accepts
#   this; the `codex exec resume` subcommand rejects `--cd`, so resume relies on
#   the spawned process's chdir instead (see #build_resume_command).
# - `-m/--model <name>` selects the model.
# - `--output-last-message <path>` writes the final assistant message to a file,
#   a runtime-independent capture of the response.
# - `-i/--image <path>` attaches an image (repeatable).
#
# == Differences from ClaudeCliAdapter ==
#
# - Session ID: Codex generates its own session UUID (the rollout filename UUID);
#   there is no `--session-id` flag. `#execute` therefore ignores the inbound
#   session_id for command construction. The UUID is captured downstream (from
#   the rollout file / first JSONL event) and passed back into `#resume`. That
#   capture lives with the transcript pipeline (#3779).
# - MCP config: Codex reads MCP servers from ~/.codex/config.toml; there is no
#   `--mcp-config` flag. `#execute`/`#resume` accept `mcp_config_path` to honor
#   the shared contract but do not pass it on the command line. Writing the
#   Codex MCP config is #3778.
# - System prompt: Codex has no `--append-system-prompt` flag. It automatically
#   reads `AGENTS.md` from the working directory, so an `append_system_prompt` is
#   delivered by writing that file before spawn. The *content* of that prompt is
#   built by the Codex prompt contribution (#3783); this adapter only delivers it.
# - No `CLAUDE_CODE_*` env vars (disable-cron / auto-memory / auto-compact) — they
#   have no Codex equivalent.
# - disallowed_tools is empty: Codex has no tool-blocking flag; the sandbox +
#   approval mode govern what the agent may do.
class CodexRuntimeAdapter
  include RuntimeCliAdapter
  include CliSpawnEnv

  class CodexCliError < StandardError; end

  attr_accessor :process_manager, :file_system, :ao_session_id

  def initialize(logger: Rails.logger)
    @logger = logger
    @process_manager = SystemProcessManager.new
    @file_system = RealFileSystemAdapter.new
  end

  # Execute a new Codex CLI session.
  #
  # @param prompt [String] The text prompt to send
  # @param session_id [String] AO session UUID — accepted for contract symmetry
  #   but not passed to Codex, which generates its own session UUID (see class doc)
  # @param working_dir [String] Working directory for the process
  # @param mcp_config_path [String, nil] Accepted for contract symmetry; Codex
  #   reads MCP servers from ~/.codex/config.toml, so this is not used here (#3778)
  # @param images [Array<Hash>, nil] Array of image hashes with a :path key
  # @param append_system_prompt [String, nil] Written to AGENTS.md before spawn
  # @param model [String, nil] Model to use (e.g., "gpt-5.4")
  # @param auto_compact_window [Integer, nil] Accepted for contract symmetry with
  #   ClaudeCliAdapter but unused: auto-compaction is a Claude Code concept driven
  #   by the CLAUDE_CODE_AUTO_COMPACT_WINDOW env var, which Codex has no analog for.
  #   ProcessLifecycleManager and the retry services pass it uniformly to whichever
  #   runtime adapter is selected, so the kwarg must exist here (#3884).
  # @return [Hash] { pid: Integer, stderr_log_path: String }
  def execute(prompt:, session_id:, working_dir:, mcp_config_path: nil, images: nil,
              append_system_prompt: nil, model: nil, auto_compact_window: nil)
    write_system_prompt(working_dir, append_system_prompt)

    command = build_command(
      prompt: prompt,
      working_dir: working_dir,
      images: images,
      model: model
    )
    spawn_process(command, working_dir: working_dir)
  end

  # Resume an existing Codex CLI session with an optional follow-up prompt.
  #
  # @param session_id [String] Codex session UUID to resume (captured downstream)
  # @param working_dir [String] Working directory for the process
  # @param prompt [String, nil] Follow-up prompt to send
  # @param images [Array<Hash>, nil] Array of image hashes with a :path key
  # @param mcp_config_path [String, nil] Accepted for contract symmetry; not used (#3778)
  # @param append_system_prompt [String, nil] Written to AGENTS.md before spawn
  # @param model [String, nil] Model to use (e.g., "gpt-5.4")
  # @param auto_compact_window [Integer, nil] Accepted for contract symmetry with
  #   ClaudeCliAdapter but unused (see #execute) — Codex has no auto-compact-window
  #   concept. Continuations and retry services pass it uniformly (#3884).
  # @return [Hash] { pid: Integer, stderr_log_path: String }
  def resume(session_id:, working_dir:, prompt: nil, images: nil, mcp_config_path: nil,
             append_system_prompt: nil, model: nil, auto_compact_window: nil)
    write_system_prompt(working_dir, append_system_prompt)

    command = build_resume_command(
      session_id: session_id,
      prompt: prompt,
      working_dir: working_dir,
      images: images,
      model: model
    )
    spawn_process(command, working_dir: working_dir)
  end

  # The CLI binary this adapter spawns. Part of the RuntimeCliAdapter contract.
  def binary_name
    "codex"
  end

  # A concise, human-readable summary of the command this adapter spawns, for
  # operator-facing session logs. Part of the RuntimeCliAdapter contract. Mirrors
  # the real `codex exec` invocation (Codex carries its MCP config in
  # .codex/config.toml, so mcp_config_path is accepted for contract symmetry but
  # has no CLI flag); the prompt is truncated since this is a debugging summary,
  # not an exact reproduction.
  def command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false)
    parts = [ binary_name, "exec" ]
    parts << "resume" << session_id if resume
    parts << "--json" << "--dangerously-bypass-approvals-and-sandbox"
    parts << prompt[0..100] if prompt.present?
    parts.join(" ")
  end

  # Build the Codex-specific exit classifier consumed by ProcessLifecycleManager.
  # Part of the RuntimeCliAdapter contract.
  def retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    CodexRetryStrategy.new(
      cli_adapter: self,
      session: session,
      file_system: file_system,
      process_manager: process_manager,
      rate_limit_tracker: rate_limit_tracker,
      logger: logger
    )
  end

  private

  # Build the `codex exec` command for a fresh session.
  def build_command(prompt:, working_dir:, images:, model:)
    cmd = [ "codex", "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "--cd", working_dir ]
    cmd << "-m" << model if model.present?
    cmd << "--output-last-message" << last_message_path(working_dir)
    append_images(cmd, images)
    cmd << prompt
    cmd
  end

  # Build the `codex exec resume <uuid>` command for a follow-up turn.
  #
  # NOTE: unlike `codex exec`, the `resume` subcommand does NOT accept `--cd`
  # (it rejects it with "unexpected argument '--cd' found" and aborts the turn).
  # The working directory is instead established by spawn_process's
  # `chdir: working_dir`, so we simply omit `--cd` here. Running from that cwd
  # also keeps Codex's cwd-based session filtering aligned with the original
  # session, while the explicit UUID makes the lookup precise regardless (#3884).
  def build_resume_command(session_id:, prompt:, working_dir:, images:, model:)
    cmd = [ "codex", "exec", "resume", session_id, "--json", "--dangerously-bypass-approvals-and-sandbox" ]
    cmd << "-m" << model if model.present?
    cmd << "--output-last-message" << last_message_path(working_dir)
    append_images(cmd, images)
    cmd << prompt if prompt.present?
    cmd
  end

  # Append a `-i <path>` flag for each provided image. Codex reads the image from
  # the path directly (no base64 inlining, unlike Claude's stream-json mode).
  def append_images(cmd, images)
    return unless images.present?

    images.each do |image|
      cmd << "-i" << image[:path]
    end
  end

  # Path Codex writes the final assistant message to. A runtime-independent
  # capture of the response, kept inside the clone alongside codex_stderr.log.
  def last_message_path(working_dir)
    File.join(working_dir, "codex_last_message.txt")
  end

  # Deliver an append_system_prompt to Codex by writing AGENTS.md, which Codex
  # reads automatically from the working directory (its only system-prompt seam —
  # there is no CLI flag analog to Claude's --append-system-prompt). The prompt
  # content is built by the Codex prompt contribution (#3783); this adapter only
  # delivers it.
  #
  # The AO-managed prompt is written below AgentsMdWriter::AO_SECTION_MARKER, and
  # any content already above that marker is preserved. This keeps the spawn-time
  # write consistent with the prepare-time AgentsMdWriter (which uses the same
  # marker): a committed AGENTS.md the repo ships flows through above the marker,
  # while the AO section below it is refreshed on every spawn/resume. Without the
  # preserve, this spawn-time write would clobber both the repo's AGENTS.md and
  # AgentsMdWriter's prepared content with orchestrator-only text.
  def write_system_prompt(working_dir, append_system_prompt)
    return if append_system_prompt.blank?

    path = File.join(working_dir, "AGENTS.md")
    marker = AgentsMdWriter::AO_SECTION_MARKER
    section = "#{marker}\n\n#{append_system_prompt}\n"

    preserved =
      if @file_system.exists?(path)
        existing = @file_system.read(path).to_s
        marker_index = existing.index(marker)
        (marker_index ? existing[0...marker_index] : existing).rstrip
      else
        ""
      end

    body = preserved.empty? ? section : "#{preserved}\n\n#{section}"
    @file_system.write(path, body)
  end

  # Spawn the Codex process. Mirrors ClaudeCliAdapter#spawn_process: stderr is
  # redirected to codex_stderr.log for the monitoring loop to tail, the process
  # gets its own group (pgroup: true) so the whole tree can be terminated, and
  # stdin/stdout are detached (the transcript pipeline reads Codex's rollout file
  # rather than stdout).
  def spawn_process(command, working_dir:)
    @logger.info "Spawning Codex CLI: #{command.join(' ')}"

    stderr_log_path = File.join(working_dir, "codex_stderr.log")

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
    env_vars = ensure_rmcp_logging(env_vars)
    env_vars = ensure_codex_home(env_vars)
    # Export the durable per-session scratch dir (AO_SESSION_SCRATCH_DIR) so
    # agents persist cross-step state on the durable volume instead of ephemeral /tmp.
    env_vars = apply_session_scratch_dir(env_vars)

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
    raise CodexCliError, "Failed to spawn Codex CLI: #{e.message}"
  end

  # Enable rmcp client logging so Codex emits a "Service initialized as client"
  # line on stderr once per connected MCP server. CodexMcpStatusDetector counts
  # these lines to turn the MCP status pill green for servers that connected but
  # were never called — the rollout records no other evidence for them (see the
  # #3991 follow-up). `warn` keeps Codex's own ERROR/WARN output (needed for MCP
  # failure detection and the auth-failure surfacing in #4036) while `rmcp=info`
  # surfaces the init line; `rmcp=info` alone would suppress those error lines.
  # An explicit RUST_LOG from the session .env is respected.
  def ensure_rmcp_logging(env_vars)
    return env_vars if env_vars["RUST_LOG"].present?

    env_vars.merge("RUST_LOG" => "warn,rmcp=info")
  end

  # Explicitly export CODEX_HOME so the spawned `codex` persists its rollout
  # JSONL transcript and state sqlite to the same directory AO reads transcripts
  # from (CodexTranscriptSource) and the auth provider writes auth.json to. The
  # resolved path is the durable CODEX_HOME, or ~/.codex when unset. Without this
  # the child could fall back to a home dir on the ephemeral overlay filesystem,
  # where rollouts are wiped on container restart/redeploy — making a later
  # `codex exec resume <thread-id>` fail with "no rollout found for thread id".
  # A CODEX_HOME provided via the session .env takes precedence.
  def ensure_codex_home(env_vars)
    return env_vars if env_vars["CODEX_HOME"].present?

    env_vars.merge("CODEX_HOME" => CodexHome.path)
  end
end
