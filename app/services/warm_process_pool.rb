# frozen_string_literal: true

require "digest"
require "fileutils"

# An idle Claude Code process kept booted for the router root, so a Quick
# Router request skips `Process.spawn`, the CLI's boot and its MCP connect.
#
# == Why, and what it saves
#
# After WarmClonePool, a Quick Router request still took ~7s from the session
# row to the router's first assistant event (study: session 24697). About 2.5s
# of that is the process: ~1s for the spawn and its preamble, ~1.3s for the CLI
# to boot, and 0.2–0.5s for its MCP handshake. A warm process has done all three
# before the request arrives.
#
# == The two constraints it is built around
#
# * No inference while warm. `claude -p --input-format stream-json` with stdin
#   held open and nothing written to it boots, connects its MCP servers and
#   waits: no transcript, no API call, no quota. Control requests (`initialize`,
#   `mcp_set_servers`, `set_model`, `mcp_status`) are answered locally.
# * Clean provenance. The session's own prompt is the first `user` message the
#   process ever sees, so it is the transcript's first turn, exactly as on a
#   cold start. Nothing is said to the process before it.
#
# == What a claim patches, and what forces a cold start
#
# The process is booted from a template of the router root's defaults
# (Sessions::ResolveSpawnDefaults), in a clone at an ordinary clone path that
# the session adopts as its own. A claim, from AgentSessionJob's fresh start:
#
# * takes the clone, fetches it to the branch tip, and refuses the process if
#   that moved a file the CLI read at boot (CLAUDE.md and friends — it does not
#   re-read them before the first message);
# * hands the session the process's pre-assigned Claude session id;
# * renames the process's CLAUDE_CONFIG_DIR and scratch dir onto the session's
#   ids, leaving a symlink at the old path for the running process;
# * after the session's own `air prepare`, refuses the process if the session's
#   `.env` or `.claude/` differ from what it booted with, or it booted with an
#   MCP server the session does not have;
# * moves the process into the session's memory cgroup;
# * writes the session's scratch dir and elicitation address to the file the
#   CLI sources before every Bash command (CLAUDE_ENV_FILE);
# * sends `initialize` with the session's system prompt, `mcp_set_servers` with
#   the session's whole server map (its self-session server and session-stamped
#   URLs), and `set_model` when the session asked for another model;
# * writes the prompt and closes stdin, so the process ends the turn and exits
#   as a cold start does. Follow-ups `--resume` exactly as before.
#
# A session whose runtime, effort, artifacts, branch or subdirectory differ from
# the template, or one started while the account, its token, the CLI binary or
# a spawn-env setting have changed since boot, starts cold. So does any claim
# that errors before the prompt is written. The pool is never why a session
# fails, and every outcome is recorded as `metadata["warm_process"]`.
#
# == Lifetime
#
# A process lives in this worker's memory: the pool holds its stdin, and the
# worker's own agent jobs are the only ones that can claim it. A deploy or a
# worker restart closes that pipe, the CLI reads EOF and exits, and the next
# one-minute WarmProcessPoolReplenishJob builds a replacement and sweeps what
# the old incarnation left on disk. No process outlives MAX_AGE.
#
# It holds no fleet slot, is not a Session row, and never reaches `needs_input`.
module WarmProcessPool
  DIRNAME = ".warm-processes"
  ID_PREFIX = "warm-"

  # The oldest process a claim accepts; the refill replaces it then.
  MAX_AGE = 60.minutes

  # How long a build waits for the CLI to boot and its MCP servers to connect.
  BOOT_TIMEOUT_SECONDS = 60

  # Per control request at claim time, on the request's critical path.
  CLAIM_TIMEOUT_SECONDS = 10

  # The refill's per-pass health probe.
  PROBE_TIMEOUT_SECONDS = 5

  # Files the CLI reads into its context at boot, from the working directory and
  # every directory above it in the repository.
  MEMORY_FILE_NAMES = %w[CLAUDE.md CLAUDE.local.md AGENTS.md].freeze

  # How much longer than MAX_AGE a live process nobody here knows about is left
  # alone before the sweep stops it.
  ORPHAN_GRACE = 15.minutes

  # How long a failed build stops the refill from trying again.
  BUILD_BACKOFF = 5.minutes

  # How old the worker's published state may be before /health calls it stale.
  # The refill republishes every minute.
  STALE_STATE_AFTER = 3.minutes

  STATE_CACHE_KEY = "warm_process_pool/state"
  OUTCOME_WINDOW = 24.hours

  @mutex = Mutex.new
  @entries = []
  @known_ids = Set.new

  class << self
    # Processes to keep. WARM_ROUTER_PROCESSES overrides the default of 1; it is
    # clamped to 0–2, and 0 turns the pool off whatever the setting says.
    def size
      configured = ENV["WARM_ROUTER_PROCESSES"].presence
      return 1 if configured.nil?

      Integer(configured, 10).clamp(0, 2)
    rescue ArgumentError
      1
    end

    def enabled?
      size.positive? && AppSetting.current(context: "WarmProcessPool.enabled?").warm_router_process_enabled?
    end

    # Whether a session's fresh start should try the pool: it is a router
    # session and the pool is on. Rescued to false, so it never fails a start.
    def serves?(session)
      enabled? && AgentRootsConfig::ROUTER_ROOT_NAMES.include?(session.metadata&.dig("agent_root_key"))
    rescue StandardError => e
      logger.warn("Could not decide whether the warm process pool serves a session", session_id: session.id, error: e.message)
      false
    end

    def root_dir
      File.join(ClonesDirectory.base, DIRNAME)
    end

    # == The claim

    # Take a ready process for a router session's fresh start, with its clone
    # brought to the branch tip. Records the outcome on a miss.
    #
    # @return [Entry, nil] the entry, whose clone the session now owns; nil when
    #   the session should clone and spawn as it would without the pool
    def claim(session)
      return nil unless serves?(session)

      entry, outcome = checkout_for(config_signature(session))
      unless entry
        record_outcome(session, outcome)
        request_refill
        return nil
      end

      catch_up!(entry, session.branch)
      # From here the clone is the session's. Written before the job can store it
      # as the session's clone, so a sweep after a worker restart never takes it.
      write_state(entry.dir, "claimed_session_id" => session.id)
      entry.state = :claimed
      request_refill
      publish_state!
      entry
    rescue Entry::Mismatch => e
      discard!(entry, reason: e.reason) if entry
      record_outcome(session, e.reason)
      nil
    rescue StandardError => e
      logger.error("Warm process claim failed; starting cold", session_id: session.id, error: "#{e.class}: #{e.message}")
      discard!(entry, reason: "claim_error") if entry
      record_outcome(session, "claim_error")
      nil
    end

    # Put the process's config and scratch directories under the session's id,
    # before anything else writes to the session's. The process keeps its own
    # path through a symlink.
    #
    # @raise [Entry::Mismatch] the session already has a config directory
    def adopt_directories!(entry, session)
      config_to = ClaudeSessionConfigDirectory.path_for(session.id)
      raise Entry::Mismatch, "session_config_dir_exists" if File.exist?(config_to) || File.symlink?(config_to)

      move_and_link(ClaudeSessionConfigDirectory.path_for(entry.id), config_to)

      scratch_from = SessionScratchDirectory.path_for(entry.id)
      scratch_to = SessionScratchDirectory.path_for(session.id)
      if File.exist?(scratch_to)
        FileUtils.rm_rf(scratch_from)
        File.symlink(scratch_to, scratch_from)
      else
        move_and_link(scratch_from, scratch_to)
      end
    end

    # Hand the session's first turn to the claimed process. Every check runs
    # before the prompt is written; see the module comment for what they are.
    #
    # @raise [Entry::Mismatch, Entry::ControlError] before the prompt was written
    def deliver!(entry, session:, working_directory:, append_system_prompt:, message_json:)
      unless entry.environment_key == environment_key
        raise Entry::Mismatch, "environment_changed"
      end
      raise Entry::Mismatch, "workspace_changed" unless digest_file(File.join(working_directory, EnvFile::FILENAME)) == entry.env_digest
      raise Entry::Mismatch, "workspace_changed" unless claude_dir_digest(working_directory) == entry.claude_dir_digest

      servers = read_mcp_servers(working_directory)
      raise Entry::Mismatch, "mcp_servers_removed" if (entry.boot_servers.keys - servers.keys).any?
      raise Entry::Mismatch, "oauth_mcp_servers" if mcp_oauth_credentials?(session)

      move_into_session_cgroup(entry, session)

      env = { "AO_SESSION_SCRATCH_DIR" => SessionScratchDirectory.ensure_for(session.id) }
            .merge(ElicitationEndpoint.spawn_env(session_id: session.id))

      entry.deliver!(
        append_system_prompt: append_system_prompt,
        mcp_servers: servers,
        model: session.config&.dig("model"),
        message_json: message_json,
        env: env,
        timeout: CLAIM_TIMEOUT_SECONDS
      )
      record_adopted(entry, session)
      AuthRecoveryCoordinator.record_spawn_credentials!(session_id: session.id, account: entry.account)
      record_outcome(session, "claimed")
    end

    # A claimed process the session will not use after all. Its clone stays
    # with the session; the sweep removes the rest once the process has exited.
    def abandon!(entry, session:, reason:)
      entry.terminate!
      record_outcome(session, reason)
      forget(entry)
    rescue StandardError => e
      logger.warn("Could not abandon a warm process cleanly", entry: entry.id, error: e.message)
    end

    # The claim is over, whichever way it went. Called from the job's `ensure`,
    # so a claim the job never finished is abandoned rather than left idle.
    def finish!(entry, session:)
      return unless entry
      return forget(entry) if entry.delivered?

      abandon!(entry, session: session, reason: "not_started")
    end

    # == The refill

    # Recycle what is dead, old or stale, sweep what a previous worker left on
    # disk, and build up to `size`. Idempotent: a pass over a full, fresh pool
    # probes each process and does nothing else.
    #
    # @return [Hash] what the pass did
    def replenish!
      result = { built: 0, recycled: 0, recycled_reasons: [], error: nil }
      sweep_orphans!

      wanted = enabled? ? size : 0
      current_env = wanted.positive? ? environment_key : nil
      template = wanted.positive? ? template_session : nil
      signature = template && config_signature(template)
      catalog = template && catalog_digest(template)

      # One entry at a time, so a failure on one can never strand the others
      # outside the registry, where nothing would ever stop them.
      take_all_ready.each do |entry|
        reason = recycle_reason(entry, wanted: wanted, environment: current_env, signature: signature, catalog: catalog)
        if reason
          discard!(entry, reason: reason)
          result[:recycled] += 1
          result[:recycled_reasons] << reason
        else
          give_back(entry)
        end
      rescue StandardError => e
        logger.warn("Could not probe a warm router process; recycling it", entry: entry.id, error: e.message)
        discard!(entry, reason: "probe_failed")
        result[:recycled] += 1
        result[:recycled_reasons] << "probe_failed"
      end

      if build_backoff?
        result[:backoff_until] = @build_failed_at + BUILD_BACKOFF
      else
        [ wanted - ready_count, 0 ].max.times do
          build!(template)
          result[:built] += 1
        end
      end

      result
    rescue StandardError => e
      logger.warn("Warm process refill failed; the next pass retries", error: "#{e.class}: #{e.message}")
      @build_failed_at = Time.current
      result[:error] = e.message.to_s.lines.first.to_s.strip.truncate(300)
      result
    ensure
      publish_state!(pass: result.merge(at: Time.current))
    end

    # The router root's defaults, as a session the Quick Router creates gets
    # them. Never saved.
    def template_session
      session = Session.new(prompt: "warm process template")
      Sessions::ResolveSpawnDefaults.call(
        session,
        agent_root_name: AgentRootsConfig.router_root_name,
        explicit_runtime: false,
        explicit_lists: { mcp_servers: false, skills: false, hooks: false, plugins: false }
      )
      session
    end

    # Whether a recent build failed. A failing build would otherwise retry every
    # minute, taking a warm clone from cold router starts each time.
    def build_backoff?
      @build_failed_at.present? && @build_failed_at > BUILD_BACKOFF.ago
    end

    def build!(template)
      id = "#{ID_PREFIX}#{Time.now.to_i}-#{SecureRandom.hex(4)}"
      dir = File.join(root_dir, id)
      FileUtils.mkdir_p(dir)
      @mutex.synchronize { @known_ids << id }
      write_state(dir, "id" => id, "created_at" => Time.current.iso8601)
      entry = nil

      clone = GitCloneService.create_clone(
        template.git_root,
        branch: template.branch,
        subdirectory: template.subdirectory,
        fallback_subdirectory: template.catalog_subdirectory,
        warm: WarmClonePool.serves?(template)
      )
      write_state(dir, "clone_path" => clone[:clone_path])
      working_directory = clone[:working_directory]

      prepare = AirPrepareService.new(session: template, working_directory: working_directory)
      if template.mcp_servers.present? || template.catalog_skills.present? || template.catalog_hooks.present? || template.catalog_plugins.present?
        prepare.prepare!
      else
        prepare.ensure_baseline_mcp_config!
      end
      boot_servers = strip_session_servers!(working_directory, prepare.injected_mcp_servers)

      claude_session_id = SecureRandom.uuid
      stdout_path = File.join(dir, "stdout.jsonl")
      env_file = File.join(dir, "session.env")
      File.write(env_file, "")
      adapter = ClaudeCliAdapter.new
      adapter.zimmer_session_id = id
      spawned = adapter.spawn_warm(
        session_id: claude_session_id,
        working_dir: working_directory,
        mcp_config_path: File.join(working_directory, McpJsonConfigFormat::MCP_CONFIG_FILENAME),
        model: template.config&.dig("model"),
        stdout_path: stdout_path,
        env_file: env_file,
        auto_compact_window: template.auto_compact_window
      )

      entry = Entry.new(
        id: id, pid: spawned[:pid], stdin: spawned[:stdin], dir: dir,
        clone_path: clone[:clone_path], working_directory: working_directory, subdirectory: clone[:subdirectory],
        claude_session_id: claude_session_id, model: template.config&.dig("model"),
        config_signature: config_signature(template), environment_key: environment_key(spawned[:account]),
        account: spawned[:account], boot_servers: boot_servers,
        env_digest: digest_file(File.join(working_directory, EnvFile::FILENAME)),
        claude_dir_digest: claude_dir_digest(working_directory),
        catalog_digest: catalog_digest(template), head: git_head(clone[:clone_path]),
        stdout_path: stdout_path, stderr_log_path: spawned[:stderr_log_path]
      )
      write_state(dir, "pid" => entry.pid, "identity" => entry.identity)

      entry.await_boot!(timeout: BOOT_TIMEOUT_SECONDS)
      register(entry)
      logger.info("Booted a warm router process", entry: id, pid: entry.pid, working_directory: working_directory)
      entry
    rescue StandardError
      # Never adopted, so everything it made goes with it, clone included. A
      # process spawned before the entry existed is stopped through its own pipe
      # and process group, since there is no entry to do it.
      if entry
        entry.terminate!
      elsif spawned
        stop_spawned(spawned)
      end
      @mutex.synchronize { @known_ids.delete(id) } if id
      remove_entry_files(id, dir, clone&.dig(:clone_path)) if id
      raise
    end

    def stop_spawned(spawned)
      spawned[:stdin].close unless spawned[:stdin].closed?
      Process.kill("TERM", -spawned[:pid])
      Process.detach(spawned[:pid])
    rescue StandardError
      nil
    end

    # Add a booted process to the pool, ready to be claimed.
    def register(entry)
      entry.state = :ready
      @mutex.synchronize do
        @known_ids << entry.id
        @entries << entry
      end
      entry
    end

    # The processes this worker holds, for the report and tests.
    def entries
      @mutex.synchronize { @entries.dup }
    end

    # Stop every process and forget them. For tests.
    def reset!
      held = @mutex.synchronize do
        all = @entries.dup
        @entries.clear
        @known_ids.clear
        all
      end
      held.each(&:terminate!)
    end

    # == The health report

    # What the pool holds and how it is doing, for /health, the REST health
    # report and `get_system_health`. The processes live in the worker; the web
    # container reads the state the worker last published.
    def report
      state = Rails.cache.read(STATE_CACHE_KEY) || {}
      now = Time.current
      entries = Array(state[:entries]).map do |entry|
        entry[:created_at] ? entry.merge(age_seconds: (now - entry[:created_at]).to_i) : entry
      end
      {
        enabled: enabled?,
        size: size,
        max_age_minutes: (MAX_AGE / 1.minute).to_i,
        stale: state[:at].nil? || state[:at] < STALE_STATE_AFTER.ago,
        entries: entries,
        last_pass: state[:pass],
        published_at: state[:at],
        outcome_window_hours: (OUTCOME_WINDOW / 1.hour).to_i,
        outcomes: outcome_counts
      }
    end

    # Router session starts in OUTCOME_WINDOW by `warm_process` outcome:
    # { "claimed" => n, "missed" => n, <reason> => n }.
    def outcome_counts(now: Time.current)
      Session.where(created_at: (now - OUTCOME_WINDOW)..now)
             .where("metadata->>'warm_process' IS NOT NULL")
             .group(Arel.sql("metadata->>'warm_process'"))
             .count
    end

    # == Signatures

    # The parts of a session's configuration a warm process cannot change after
    # boot. A claim needs the session's to equal the template's.
    def config_signature(session)
      {
        "runtime" => session.agent_runtime.to_s,
        "git_root" => session.git_root.to_s,
        "branch" => session.branch.to_s,
        "subdirectory" => session.subdirectory.presence,
        "mcp_servers" => (Array(session.mcp_servers) + Array(session.plugin_mcp_servers)).map(&:to_s).uniq.sort,
        "skills" => Array(session.catalog_skills).map(&:to_s).sort,
        "hooks" => Array(session.catalog_hooks).map(&:to_s).sort,
        "plugins" => Array(session.catalog_plugins).map(&:to_s).sort,
        "effort" => session.effort_override.presence,
        "auto_compact_window" => session.auto_compact_window
      }
    end

    # What the spawn environment would hand a process started now, beyond the
    # session itself: the account and its token, the CLI binary, the GitHub token
    # map, and the settings and extensions that write spawn env. A change to any of them
    # recycles the process.
    def environment_key(account = ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME))
      Digest::SHA256.hexdigest([
        account&.id,
        AuthRecoveryCoordinator.credential_fingerprint(account),
        cli_fingerprint,
        AppSetting.mcp_tool_search_enabled?,
        Zimmer::ExtensionRegistry.spawn_env_contributions(runtime: "claude_code").sort.to_json,
        GithubTokens.fingerprint
      ].to_json)
    end

    # The catalog entries the template resolves to. A change recycles the
    # process before a claim has to find it at its `air prepare`.
    def catalog_digest(template)
      wanted = {
        roots: [ AgentRootsConfig.router_root_name ],
        mcp: config_signature(template)["mcp_servers"],
        skills: Array(template.catalog_skills),
        hooks: Array(template.catalog_hooks),
        plugins: Array(template.catalog_plugins)
      }
      Digest::SHA256.hexdigest(wanted.map do |type, ids|
        entries = AirCatalogService.entries_for(type)
        [ type, entries.select { |name, _| ids.any? { |id| name.to_s == id || name.to_s.end_with?("/#{id}") } }.sort.to_h ]
      end.to_json)
    end

    # The `claude` binary on PATH and when it was written. An update replaces
    # the file, so this changes when the version does, without running it.
    def cli_fingerprint
      binary = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "claude") }.find { |path| File.executable?(path) }
      return nil unless binary

      real = File.realpath(binary)
      "#{real}@#{File.mtime(real).to_i}"
    end

    def claude_dir_digest(working_directory)
      root = File.join(working_directory, ".claude")
      return nil unless File.directory?(root)

      digest = Digest::SHA256.new
      Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.each do |relative|
        path = File.join(root, relative)
        next unless File.file?(path)

        digest << relative << "\0" << File.binread(path) << "\0"
      end
      digest.hexdigest
    end

    # Whether the CLI would have read any of these changed paths at boot: a
    # memory file in the working directory or a directory above it, anything
    # under a `.claude/` there, the working directory's `.mcp.json`, and — for a
    # root that lives in a subdirectory — anything inside that subdirectory,
    # which covers the files its CLAUDE.md imports.
    def boot_context_changed?(changed_paths, subdirectory)
      sub = subdirectory.to_s.delete_suffix("/")
      ancestors = [ "" ]
      sub.split("/").each { |part| ancestors << [ ancestors.last, part ].reject(&:empty?).join("/") } if sub.present?

      changed_paths.any? do |path|
        dir = File.dirname(path)
        dir = "" if dir == "."
        next true if sub.present? && path.start_with?("#{sub}/")
        next true if MEMORY_FILE_NAMES.include?(File.basename(path)) && ancestors.include?(dir)
        next true if path == [ sub, McpJsonConfigFormat::MCP_CONFIG_FILENAME ].reject(&:empty?).join("/")

        ancestors.any? { |ancestor| path.start_with?([ ancestor, ".claude/" ].reject(&:empty?).join("/")) }
      end
    end

    private

    # Under the mutex: the newest ready entry whose signature matches, taken
    # out of the registry so nothing else can write to it.
    #
    # @return [Array(Entry, nil), Array(nil, String)]
    def checkout_for(signature)
      @mutex.synchronize do
        ready = @entries.select { |entry| entry.state == :ready }
        return [ nil, "missed" ] if ready.empty?

        entry = ready.select { |candidate| candidate.config_signature == signature }.max_by(&:created_at)
        return [ nil, "config_mismatch" ] unless entry

        @entries.delete(entry)
        entry.state = :claiming
        entry
      end.then do |entry|
        next [ entry, nil ] if entry.alive? && entry.age_seconds <= MAX_AGE.to_i

        discard!(entry, reason: "stale")
        [ nil, "stale" ]
      end
    end

    # Fetch the clone to the branch tip, unless that would change what the
    # process already read at boot.
    #
    # @raise [Entry::Mismatch]
    def catch_up!(entry, branch)
      git = ->(*args) { GitCloneService.run_git_command(args, cwd: entry.clone_path, timeout: WarmClonePool::FETCH_TIMEOUT_SECONDS) }
      git.call("fetch", "--quiet", "origin", branch)
      changed = GitCloneService.run_git_command(
        [ "diff", "--name-only", "--no-renames", entry.head.to_s, "FETCH_HEAD" ], cwd: entry.clone_path, timeout: WarmClonePool::FETCH_TIMEOUT_SECONDS
      ).to_s.split("\n").map(&:strip).reject(&:empty?)
      raise Entry::Mismatch, "boot_context_changed" if boot_context_changed?(changed, entry.subdirectory)

      git.call("reset", "--quiet", "--hard", "FETCH_HEAD")
    rescue GitCloneService::GitError => e
      raise Entry::Mismatch.new("fetch_failed", e.message)
    end

    def recycle_reason(entry, wanted:, environment:, signature:, catalog:)
      return "disabled" if wanted.zero?
      return "exited" unless entry.alive?
      return "aged_out" if entry.age_seconds > MAX_AGE.to_i
      return "environment_changed" if entry.environment_key != environment
      return "config_changed" if entry.config_signature != signature
      return "catalog_changed" if entry.catalog_digest != catalog
      return "surplus" if ready_count >= wanted

      failed = entry.mcp_status(timeout: PROBE_TIMEOUT_SECONDS).select { |server| server["status"] == "failed" }
      "mcp_failed" if failed.any?
    rescue Entry::ControlError
      "unresponsive"
    end

    def take_all_ready
      @mutex.synchronize do
        ready = @entries.select { |entry| entry.state == :ready }
        @entries -= ready
        ready.each { |entry| entry.state = :probing }
      end
    end

    def give_back(entry)
      entry.state = :ready
      @mutex.synchronize { @entries << entry }
    end

    def ready_count
      @mutex.synchronize { @entries.count { |entry| entry.state == :ready } }
    end

    # Stop a process nobody has adopted and remove what it made. Its memory
    # cgroup and entry directory wait for the sweep, since the process is still
    # exiting and its cgroup cannot be removed while it holds a pid.
    def discard!(entry, reason:)
      logger.info("Recycling a warm router process", entry: entry.id, reason: reason, age_seconds: entry.age_seconds)
      entry.terminate!
      @mutex.synchronize { @entries.delete(entry) }
      forget(entry)
      AtomicCloneRemoval.remove(entry.clone_path) if entry.clone_path.present? && File.exist?(entry.clone_path)
      remove_warm_paths(entry.id)
    end

    def forget(entry)
      @mutex.synchronize { @known_ids.delete(entry.id) }
    end

    def remove_entry_files(id, dir, clone_path)
      AtomicCloneRemoval.remove(clone_path) if clone_path.present? && File.exist?(clone_path)
      remove_warm_paths(id)
      remove_cgroup(id)
      FileUtils.rm_rf(dir)
    end

    # The process's own config and scratch directories, or — once a claim moved
    # them onto a session — the symlinks left at their old paths. A symlink is
    # unlinked, never followed: what it points at is the session's.
    def remove_warm_paths(id)
      { ClaudeSessionConfigDirectory => ClaudeSessionConfigDirectory.path_for(id),
        SessionScratchDirectory => SessionScratchDirectory.path_for(id) }.each do |owner, path|
        if File.symlink?(path)
          File.delete(path)
        else
          owner.cleanup_for(id)
        end
      end
    end

    def remove_cgroup(id)
      cgroup = SessionMemoryCgroup.for(id)
      SessionMemoryCgroup.remove_if_empty(cgroup.path) if cgroup&.exists?
    end

    # Entry directories no live entry of this process owns: left by a worker
    # that has since restarted, by a discarded or abandoned process, or by an
    # adopted one. Nothing is removed while its process runs. A claimed or
    # adopted entry's clone is the session's and is never touched; only its
    # symlinks, cgroup and directory go.
    def sweep_orphans!
      return unless Dir.exist?(root_dir)

      known = @mutex.synchronize { @known_ids.dup }
      Dir.children(root_dir).each do |id|
        next if known.include?(id) || !id.start_with?(ID_PREFIX)

        dir = File.join(root_dir, id)
        state = read_state(dir)
        identity = state["identity"]
        claimed = state["claimed_session_id"].present? || state["adopted_session_id"].present?

        if identity.present? && AgentProcessLiveness.classify(identity) == :alive
          # A claimed process is a session's turn (or one being stopped). An
          # unclaimed one unknown here may be a claim this worker cannot see,
          # until it is older than anything the pool would still hand out.
          next if claimed || !orphan_expired?(state)

          Process.kill("TERM", -identity["pid"].to_i)
          next
        end

        remove_entry_files(id, dir, claimed ? nil : state["clone_path"])
      rescue StandardError => e
        logger.warn("Could not sweep a warm process directory", entry: id, error: e.message)
      end
    end

    # Bookkeeping, so it can never cost the claim it follows: the one-minute cron
    # refills the pool anyway.
    def request_refill
      WarmProcessPoolReplenishJob.perform_later
    rescue StandardError => e
      logger.warn("Could not enqueue a warm process refill", error: e.message)
    end

    def orphan_expired?(state)
      created = Time.zone.parse(state["created_at"].to_s)
      created.nil? || created < (MAX_AGE + ORPHAN_GRACE).ago
    end

    def record_adopted(entry, session)
      write_state(entry.dir, "adopted_session_id" => session.id, "adopted_at" => Time.current.iso8601)
    rescue StandardError => e
      logger.warn("Could not record a warm process adoption", entry: entry.id, error: e.message)
    end

    def move_and_link(from, to)
      FileUtils.mkdir_p(File.dirname(to))
      File.rename(from, to)
      File.symlink(to, from)
    end

    # Move every process in the entry's memory cgroup — the CLI and its MCP
    # children — into the session's, where a cold start would have put them.
    # Best effort, as for a cold start: an unbounded session beats a failed one.
    def move_into_session_cgroup(entry, session)
      source = SessionMemoryCgroup.for(entry.id)
      target = SessionMemoryCgroup.for(session.id)
      return unless source&.exists? && target&.prepare!

      File.read(source.procs_path).split.each do |pid|
        File.write(target.procs_path, pid)
      rescue Errno::ESRCH
        next
      end
      SessionMemoryCgroup.remove_if_empty(source.path)
    rescue SystemCallError => e
      logger.warn("Could not move a warm process into the session's memory cgroup", entry: entry.id, error: e.message)
    end

    # Drop the servers `air prepare` injected for a session, which the template
    # has no id for (the self-session server above all). The claim sets them.
    #
    # @return [Hash] the servers the process boots with
    def strip_session_servers!(working_directory, injected)
      path = File.join(working_directory, McpJsonConfigFormat::MCP_CONFIG_FILENAME)
      return {} unless File.exist?(path)

      config = JSON.parse(File.read(path))
      servers = (config[McpJsonConfigFormat::SERVERS_KEY] || {}).except(*Array(injected))
      config[McpJsonConfigFormat::SERVERS_KEY] = servers
      File.write(path, JSON.pretty_generate(config))
      servers
    end

    # Whether the OAuth gate wrote MCP OAuth credentials for the session. They
    # land in the config directory after the process booted, and a server whose
    # config does not change at the claim is not reconnected to read them.
    def mcp_oauth_credentials?(session)
      path = ClaudeSessionConfigDirectory.credentials_path_for(session.id)
      return false unless File.exist?(path)

      JSON.parse(File.read(path))["mcpOAuth"].present?
    rescue JSON::ParserError
      true
    end

    def read_mcp_servers(working_directory)
      path = File.join(working_directory, McpJsonConfigFormat::MCP_CONFIG_FILENAME)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))[McpJsonConfigFormat::SERVERS_KEY] || {}
    end

    def digest_file(path)
      File.exist?(path) ? Digest::SHA256.file(path).hexdigest : nil
    end

    def git_head(clone_path)
      GitCloneService.run_git_command([ "rev-parse", "HEAD" ], cwd: clone_path, timeout: 10).to_s.strip
    end

    def write_state(dir, attrs)
      path = File.join(dir, "state.json")
      File.write(path, JSON.generate(read_state(dir).merge(attrs)))
    end

    def read_state(dir)
      path = File.join(dir, "state.json")
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end

    def record_outcome(session, outcome)
      session.merge_metadata!("warm_process" => outcome)
    rescue StandardError => e
      logger.warn("Could not record the warm process outcome", session_id: session.id, error: e.message)
    end

    # Kept where the web container can read it: the processes live in the
    # worker's memory.
    def publish_state!(pass: nil)
      previous = Rails.cache.read(STATE_CACHE_KEY) || {}
      entries = @mutex.synchronize { @entries.map(&:to_report) }
      Rails.cache.write(STATE_CACHE_KEY, { at: Time.current, entries: entries, pass: pass || previous[:pass] }, expires_in: 1.day)
    rescue StandardError => e
      logger.warn("Could not publish the warm process pool state", error: e.message)
    end

    def logger
      StructuredLogger.new({ service: "WarmProcessPool" })
    end
  end
end
