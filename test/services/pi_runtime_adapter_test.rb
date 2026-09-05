# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class PiRuntimeAdapterTest < ActiveSupport::TestCase
  WORKING_DIR = "/tmp/pi-adapter-test"
  SESSION_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  setup do
    @adapter = PiRuntimeAdapter.new
    @process_manager = MockProcessManager.new
    @file_system = MockFileSystemAdapter.new
    @adapter.process_manager = @process_manager
    @adapter.file_system = @file_system
  end

  # #815: same as Codex and Claude — a runtime the wrapper misses runs unbounded.
  test "spawn_process runs Pi inside the session's memory cgroup" do
    @file_system.mkdir_p(WORKING_DIR)

    with_delegated_cgroup_parent do |parent|
      @adapter.zimmer_session_id = 5250
      @adapter.send(:spawn_process, [ "pi", "--session-dir", WORKING_DIR ], working_dir: WORKING_DIR)

      spawned = @process_manager.spawned_processes.first

      assert_equal "/bin/sh", spawned[:command].first
      assert_includes spawned[:command], File.join(parent, "session-5250", "cgroup.procs")
      assert_equal [ "pi", "--session-dir", WORKING_DIR ], spawned[:command].last(3)
    end
  end

  test "spawn_process leaves Pi's command alone where there is no cgroup to enter" do
    @file_system.mkdir_p(WORKING_DIR)

    without_delegated_cgroup_parent do
      @adapter.zimmer_session_id = 5251
      @adapter.send(:spawn_process, [ "pi" ], working_dir: WORKING_DIR)

      assert_equal [ "pi" ], @process_manager.spawned_processes.first[:command]
    end
  end

  # #981: same as Codex and Claude — a runtime this misses sizes its test parallelism off
  # the whole droplet's processor count, and eight such sessions filled the worker's cgroup.
  test "spawn_process caps Pi's parallel test workers" do
    @file_system.mkdir_p(WORKING_DIR)
    @adapter.send(:spawn_process, [ "pi" ], working_dir: WORKING_DIR)

    assert_equal CliSpawnEnv::DEFAULT_TEST_PARALLELISM.to_s,
      @process_manager.spawned_processes.first[:env]["PARALLEL_WORKERS"]
  end

  test "binary_name and stderr log filename identify the Pi runtime" do
    assert_equal "pi", @adapter.binary_name
    assert_equal "pi_stderr.log", PiRuntimeAdapter.stderr_log_filename
    assert_equal File.join(WORKING_DIR, "pi_stderr.log"), PiRuntimeAdapter.stderr_log_path(WORKING_DIR)
    assert_equal "Pi CLI", PiRuntimeAdapter.cli_label
  end

  test "execute builds a non-interactive JSON-mode command carrying the Zimmer session id" do
    execute!

    assert_equal "pi", command[0]
    assert_includes command, "-p"
    assert_flag_value "--mode", "json"
    # Zimmer's id IS Pi's id — the flag Codex has no analog for.
    assert_flag_value "--session-id", SESSION_ID
    assert_flag_value "--session-dir", File.join(WORKING_DIR, ".pi", "sessions")
  end

  # Without --approve, Pi treats the .pi/skills and .mcp.json Zimmer just wrote
  # as untrusted project-local files and, having no TTY in -p mode to ask about
  # them, silently ignores everything prepared for the session.
  test "execute trusts the project-local files Zimmer prepared" do
    execute!

    assert_includes command, "--approve"
  end

  # Everything after `--` is message content, so a prompt starting with a dash is
  # not read as a flag.
  test "the prompt is passed after the option terminator" do
    execute!(prompt: "-- not a flag")

    terminator = command.index("--")
    assert terminator, "expected a `--` terminator in #{command.inspect}"
    assert_equal "-- not a flag", command.last
    assert_operator command.index("-- not a flag"), :>, terminator
  end

  test "the model is passed through verbatim as a provider-qualified pattern" do
    execute!(model: "anthropic/claude-opus-4-6")

    assert_flag_value "--model", "anthropic/claude-opus-4-6"
  end

  test "no --model flag is passed when the session has no model" do
    execute!(model: nil)

    assert_not_includes command, "--model"
  end

  # The orchestrator prompt runs to many kilobytes; inline argv would risk E2BIG.
  test "the append system prompt is staged to a file and passed by path" do
    execute!(append_system_prompt: "You are running inside Zimmer.")

    staged = File.join(WORKING_DIR, "pi_system_prompt.md")
    assert_flag_value "--append-system-prompt", staged
    assert_equal "You are running inside Zimmer.", @file_system.read(staged)
  end

  test "no system prompt flag is passed when there is nothing to append" do
    execute!(append_system_prompt: nil)

    assert_not_includes command, "--append-system-prompt"
  end

  test "images are attached with Pi's @path message syntax" do
    execute!(images: [ { path: "/tmp/shot.png" } ])

    assert_includes command, "@/tmp/shot.png"
  end

  # Pi has no `resume` subcommand: re-invoking with the same --session-id
  # continues that session's tree.
  test "resume reuses the same session id rather than a resume subcommand" do
    @adapter.resume(session_id: SESSION_ID, working_dir: WORKING_DIR, prompt: "keep going")

    assert_not_includes command, "resume"
    assert_flag_value "--session-id", SESSION_ID
    assert_equal "keep going", command.last
  end

  test "resume tolerates a blank prompt" do
    @adapter.resume(session_id: SESSION_ID, working_dir: WORKING_DIR, prompt: nil)

    assert_equal "--", command.last
  end

  test "the session directory is created before spawning" do
    execute!

    assert @file_system.directory?(File.join(WORKING_DIR, ".pi", "sessions"))
  end

  test "the spawn is process-grouped with detached stdio" do
    execute!

    options = @process_manager.spawned_processes.last[:options]
    assert_equal WORKING_DIR, options[:chdir]
    assert options[:pgroup]
    assert_equal File::NULL, options[:in]
    assert_equal File::NULL, options[:out]
  end

  test "PI_CODING_AGENT_DIR is exported so credentials resolve off the durable path" do
    execute!

    assert_equal PiHome.path, spawn_env["PI_CODING_AGENT_DIR"]
  end

  # PI_OFFLINE would also suppress Pi's provider model-catalog refresh, which a
  # session actually depends on — so only the two pointless calls are silenced.
  test "the pointless startup network calls are silenced but the runtime is not put offline" do
    execute!

    assert_equal "1", spawn_env["PI_SKIP_VERSION_CHECK"]
    assert_equal "0", spawn_env["PI_TELEMETRY"]
    assert_nil spawn_env["PI_OFFLINE"]
  end

  # Pi's hook and plugin extensions fall back to discovering `./air.json` in the
  # working directory, which is a clone of whatever repository the session works
  # on. Naming Zimmer's generated files is what stops a cloned repo deciding which
  # hooks run in a Zimmer session.
  test "the Pi extensions are pointed at the AIR config PiAirBridge generated" do
    PiAirBridge.new(session: pi_session, working_directory: WORKING_DIR, file_system: @file_system)
      .write!
    execute!

    assert_equal PiAirBridge.hooks_air_path(WORKING_DIR), spawn_env["PI_HOOKS_AIR"]
    assert_equal PiAirBridge.plugins_air_path(WORKING_DIR), spawn_env["PI_PLUGINS_CONFIG"]
  end

  # A dangling PI_PLUGINS_CONFIG makes the extension throw and fall back to
  # discovery, so a session prepared without the bridge must get no variable at
  # all rather than one pointing at nothing.
  test "no AIR override is exported when the bridge has not written its config" do
    execute!

    assert_nil spawn_env["PI_HOOKS_AIR"]
    assert_nil spawn_env["PI_PLUGINS_CONFIG"]
  end

  test "execute and resume both refuse a nil working directory" do
    assert_raises(PiRuntimeAdapter::PiCliError) do
      @adapter.execute(prompt: "hi", session_id: SESSION_ID, working_dir: nil)
    end
    assert_raises(PiRuntimeAdapter::PiCliError) do
      @adapter.resume(session_id: SESSION_ID, working_dir: nil)
    end
  end

  test "command_summary starts with the binary name and names the session" do
    summary = @adapter.command_summary(session_id: SESSION_ID, prompt: "do the thing")

    assert summary.start_with?("pi"), summary
    assert_includes summary, SESSION_ID
  end

  test "retry_strategy returns the Pi classifier" do
    strategy = @adapter.retry_strategy(
      session: Session.new(agent_runtime: "pi"),
      file_system: @file_system,
      process_manager: @process_manager,
      rate_limit_tracker: nil
    )

    assert_instance_of PiRetryStrategy, strategy
  end

  private

  def pi_session
    sessions(:active_session).tap do |session|
      session.update!(agent_runtime: "pi", catalog_hooks: [], catalog_plugins: [])
    end
  end

  def execute!(prompt: "do the thing", model: nil, images: nil, append_system_prompt: nil)
    @adapter.execute(
      prompt: prompt,
      session_id: SESSION_ID,
      working_dir: WORKING_DIR,
      model: model,
      images: images,
      append_system_prompt: append_system_prompt
    )
  end

  def command
    @process_manager.spawned_processes.last[:command]
  end

  def spawn_env
    @process_manager.spawned_processes.last[:env]
  end

  def assert_flag_value(flag, value)
    index = command.index(flag)
    assert index, "expected #{flag} in #{command.inspect}"
    assert_equal value, command[index + 1]
  end

  # --- the provider key reaches the process ---------------------------------
  #
  # This is the step that is easy to assume some other layer performs. Nothing
  # does: the clone's `.env` is written from SecretsLoader, which reads Rails
  # encrypted `mcp_secrets` only and never consults SecretProviders — so without
  # this, a key set on the Inference page's Pi tab lands in the Parameter Store
  # and never reaches Pi.

  test "spawn_process puts the OpenRouter key from the ${VAR} chain into Pi's environment" do
    @file_system.mkdir_p(WORKING_DIR)

    with_chain_holding(ManagedSecret::OPENROUTER_API_KEY => "sk-or-v1-from-the-store") do
      @adapter.send(:spawn_process, [ "pi" ], working_dir: WORKING_DIR)
    end

    assert_equal "sk-or-v1-from-the-store",
      @process_manager.spawned_processes.first[:env][ManagedSecret::OPENROUTER_API_KEY]
  end

  test "a value in the clone's own .env wins over the chain" do
    @file_system.mkdir_p(WORKING_DIR)
    @file_system.write(File.join(WORKING_DIR, ".env"),
      "#{ManagedSecret::OPENROUTER_API_KEY}=sk-or-v1-this-repos-own-account")

    with_chain_holding(ManagedSecret::OPENROUTER_API_KEY => "sk-or-v1-from-the-store") do
      @adapter.send(:spawn_process, [ "pi" ], working_dir: WORKING_DIR)
    end

    assert_equal "sk-or-v1-this-repos-own-account",
      @process_manager.spawned_processes.first[:env][ManagedSecret::OPENROUTER_API_KEY]
  end

  test "no key in the chain leaves the variable unset rather than blank" do
    @file_system.mkdir_p(WORKING_DIR)

    with_chain_holding({}) do
      @adapter.send(:spawn_process, [ "pi" ], working_dir: WORKING_DIR)
    end

    assert_nil @process_manager.spawned_processes.first[:env][ManagedSecret::OPENROUTER_API_KEY]
  end

  # A store Zimmer cannot reach must not stop a Pi session spawning. Pi reports
  # its own `not_ready` if the key never arrives, which is a far better failure
  # than a session that never starts.
  test "an unreachable store does not stop the spawn" do
    @file_system.mkdir_p(WORKING_DIR)
    failing = Object.new
    failing.define_singleton_method(:get) do |_variable|
      raise ParameterStore::StoreError.new("boom", 503)
    end

    SecretProviders.stub(:chain, failing) do
      @adapter.send(:spawn_process, [ "pi" ], working_dir: WORKING_DIR)
    end

    assert_equal 1, @process_manager.spawned_processes.size
    assert_nil @process_manager.spawned_processes.first[:env][ManagedSecret::OPENROUTER_API_KEY]
  end

  def with_chain_holding(values)
    chain = Object.new
    chain.define_singleton_method(:get) { |variable| values[variable] }
    SecretProviders.stub(:chain, chain) { yield }
  end
end
