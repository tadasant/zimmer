# frozen_string_literal: true

require "test_helper"
require "open3"
require "mocha/minitest"

# Tests for AirPrepareService — the thin orchestrator that installs the AIR CLI,
# picks the runtime's AIR adapter from RuntimeRegistry, shells out to
# `air prepare`, and hands off MCP-config post-processing to the runtime's
# RuntimeConfigPostProcessor. The Zimmer-specific .mcp.json tweaks are tested
# directly against ClaudeMcpConfigPostProcessor in
# claude_mcp_config_post_processor_test.rb.
class AirPrepareServiceTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
    @session.update!(
      mcp_servers: [ "playwright-custom" ],
      catalog_skills: [ "zimmer-run-tests" ],
      metadata: { "agent_root_key" => "agent-orchestrator" }
    )
    @working_dir = Dir.mktmpdir
    @mock_fs = MockFileSystemAdapter.new

    # Override AIR_INSTALL_DIR to a writable temp directory so ensure_air_installed!
    # doesn't try to create /opt/air-cli (which requires root in CI).
    # Pre-create the version marker AND a working fake binary so ensure_air_installed!
    # is a no-op — tests exercise the air prepare command, not the npm install bootstrap.
    @tmp_air_dir = Dir.mktmpdir("air-cli-test")
    FileUtils.touch(File.join(@tmp_air_dir, ".air-version-#{AirPrepareService::AIR_CLI_VERSION}"))
    create_fake_air_binary(@tmp_air_dir)
    @original_air_dir = AirPrepareService::AIR_INSTALL_DIR
    AirPrepareService.send(:remove_const, :AIR_INSTALL_DIR)
    AirPrepareService.const_set(:AIR_INSTALL_DIR, @tmp_air_dir)

    # Self-session catalog entry requires ZIMMER_STAGING_API_KEY
    ENV["ZIMMER_STAGING_API_KEY"] = "test-staging-api-key"
  end

  teardown do
    AirPrepareService.send(:remove_const, :AIR_INSTALL_DIR)
    AirPrepareService.const_set(:AIR_INSTALL_DIR, @original_air_dir)
    FileUtils.rm_rf(@working_dir) if @working_dir && File.exist?(@working_dir)
    FileUtils.rm_rf(@tmp_air_dir) if @tmp_air_dir && File.exist?(@tmp_air_dir)
    ENV.delete("ZIMMER_STAGING_API_KEY")
  end

  test "ensure_air_installed! re-installs when binary is missing despite version marker" do
    # Remove the fake binary but keep the version marker — simulates a corrupted install
    File.delete(File.join(@tmp_air_dir, "node_modules", ".bin", "air"))

    install_called = false

    stub_air_subprocess(proc { |*args, **opts|
      cmd_args = args.is_a?(Array) ? args : [ args ]
      if cmd_args.any? { |a| a.to_s.include?("npm") }
        install_called = true
        # Simulate npm install creating a working binary
        create_fake_air_binary(@tmp_air_dir)
      end
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    assert install_called, "npm install should be called when binary is missing"
  end

  test "install_air_cli! installs the codex adapter alongside the claude adapter and pins every package to AIR_CLI_VERSION" do
    # Force a reinstall by removing the fake binary so the install path runs.
    File.delete(File.join(@tmp_air_dir, "node_modules", ".bin", "air"))

    install_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      cmd_args = args.is_a?(Array) ? args : [ args ]
      if cmd_args.any? { |a| a.to_s.include?("npm") }
        install_cmd = cmd_args
        # Simulate npm install producing a working binary so the health check passes.
        create_fake_air_binary(@tmp_air_dir)
      end
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      AirPrepareService.ensure_air_installed!
    end

    assert_not_nil install_cmd, "npm install should be invoked when the binary is missing"

    version = AirPrepareService::AIR_CLI_VERSION
    expected_packages = [
      "@pulsemcp/air-cli@#{version}",
      "@pulsemcp/air-adapter-claude@#{version}",
      "@pulsemcp/air-adapter-codex@#{version}",
      "@pulsemcp/air-secrets-env@#{version}",
      "@pulsemcp/air-provider-github@#{version}"
    ]
    expected_packages.each do |pkg|
      assert_includes install_cmd, pkg,
        "AIR install set must include #{pkg} so `air prepare` can load it"
    end

    # Every @pulsemcp/air-* package must be pinned to the same version (lockstep).
    air_packages = install_cmd.select { |a| a.to_s.start_with?("@pulsemcp/air-") }
    assert_equal 5, air_packages.length,
      "expected exactly the 5 pinned AIR packages, got: #{air_packages.inspect}"
    air_packages.each do |pkg|
      assert pkg.end_with?("@#{version}"),
        "#{pkg} must be pinned to AIR_CLI_VERSION (#{version}) — AIR packages move in lockstep"
    end
  end

  test "ensure_air_installed! trusts the marker and does NOT reinstall when binary exists but crashes" do
    # Replace the working binary with one that exits non-zero — simulates a crashing binary.
    # Previously we auto-reinstalled in this case; that behavior caused races in parallel CI
    # (a spurious --version failure triggered rm_rf while another worker was running air resolve).
    # Recovery now requires removing the marker or bumping AIR_CLI_VERSION.
    binary_path = File.join(@tmp_air_dir, "node_modules", ".bin", "air")
    File.write(binary_path, "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, binary_path)

    install_called = false

    stub_air_subprocess(proc { |*args, **opts|
      cmd_args = args.is_a?(Array) ? args : [ args ]
      if cmd_args.any? { |a| a.to_s.include?("npm") }
        install_called = true
      end
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      AirPrepareService.ensure_air_installed!
    end

    refute install_called, "npm install should NOT be called when marker+binary exist, even if binary crashes"
  end

  test "prepare! calls AIR CLI with correct arguments and passes secrets env hash" do
    captured_calls = []

    stub_air_subprocess(proc { |*args, **opts|
      captured_calls << args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    # Last captured call is the AIR prepare invocation
    prepare_call = captured_calls.last
    assert_not_nil prepare_call

    # First argument should be the secrets env hash, with AIR_CONFIG pointing at the
    # configured air.json — AIR CLI resolves the catalog from that env var instead of
    # being passed --config explicitly.
    env_hash = prepare_call.first
    assert_instance_of Hash, env_hash, "First argument to the air prepare exec should be a Hash (secrets env)"
    assert_equal AirCatalogService.air_json_path, env_hash["AIR_CONFIG"],
      "env hash should set AIR_CONFIG so the CLI resolves the catalog from Rails config"

    # Remaining arguments are the command
    cmd_args = prepare_call[1..]
    air_bin = File.join(AirPrepareService::AIR_INSTALL_DIR, "node_modules", ".bin", "air")
    assert_includes cmd_args, air_bin
    assert_includes cmd_args, "prepare"
    assert_includes cmd_args, "claude"
    refute_includes cmd_args, "--config",
      "AIR config path is supplied via AIR_CONFIG env, not --config flag"
    assert_includes cmd_args, "--target"
    assert_includes cmd_args, @working_dir
    assert_includes cmd_args, "--root"
    assert_includes cmd_args, "agent-orchestrator"
    assert_includes cmd_args, "--skill"
    assert_includes cmd_args, "zimmer-run-tests"
    assert_includes cmd_args, "--mcp-server"
    assert_includes cmd_args, "playwright-custom"
  end

  # --- Stale/renamed skill id graceful degradation ---------------------------
  #
  # A session's catalog_skills are validated at creation time, but the catalog
  # evolves independently: a local skill can be renamed (`pr` → `open-pr`) or
  # removed long after the session's config was frozen. `air prepare` hard-rejects
  # an unknown skill id with exit 1, which without this scrub AirPrepareError-bricks
  # session startup entirely. These assert the id is dropped-with-a-warning instead.
  # update_column is used to plant a stale id past the model's create-time
  # validation, mirroring a catalog that changed after the session was saved.

  test "prepare! drops a stale/renamed skill id not in the catalog and prepares with the survivors" do
    @session.update_column(:catalog_skills, [ "zimmer-run-tests", "renamed-away-skill" ])
    AlertService.stubs(:raise_alert)

    captured_cmd = nil
    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      # Must NOT raise — a stale id degrades to a drop, not a brick.
      service.prepare!
    end

    cmd_args = captured_cmd[1..]
    skill_values = cmd_args.each_cons(2).select { |a, _| a == "--skill" }.map(&:last)
    assert_equal [ "zimmer-run-tests" ], skill_values,
      "only the catalog-resident skill should be requested; the stale id must be dropped " \
      "(and leave no dangling --skill flag)"
    refute_includes cmd_args, "renamed-away-skill",
      "the stale skill id must never reach `air prepare`, which would hard-reject it"
  end

  test "prepare! emits a session self-heal alert when it drops a stale skill id" do
    @session.update_column(:catalog_skills, [ "zimmer-run-tests", "renamed-away-skill" ])

    AlertService.expects(:raise_alert).with(
      "Session self-healed: stale catalog skill(s) removed",
      has_entries(
        source: "AirPrepareService#run_air_prepare!",
        dedup_key: "session_stale_skills_#{@session.id}"
      )
    ).once

    stub_air_subprocess(proc { |*args, **opts|
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end
  end

  test "prepare! does not alert or drop when every requested skill exists in the catalog" do
    @session.update_column(:catalog_skills, [ "zimmer-run-tests" ])
    AlertService.expects(:raise_alert).never

    captured_cmd = nil
    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    assert_includes captured_cmd[1..], "zimmer-run-tests"
  end

  test "prepare! does NOT strip skills when the catalog failed to load (SkillsConfig empty)" do
    # If the catalog load failed, SkillsConfig.all rescues to [] and every id would
    # look stale — stripping the whole list would be destructive. Guard: leave the
    # requested set intact and let `air prepare` resolve the catalog itself.
    @session.update_column(:catalog_skills, [ "zimmer-run-tests", "renamed-away-skill" ])
    SkillsConfig.stubs(:all).returns([])
    AlertService.expects(:raise_alert).never

    captured_cmd = nil
    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    cmd_args = captured_cmd[1..]
    assert_includes cmd_args, "zimmer-run-tests"
    assert_includes cmd_args, "renamed-away-skill",
      "with an unloadable catalog we must not strip anything; air prepare resolves it"
  end

  test "prepare! sources the AIR adapter id from the session's runtime registry bundle" do
    # The adapter passed to `air prepare <adapter>` must come from
    # RuntimeRegistry (via session.runtime.air_adapter_name), not a hardcoded
    # literal. Stub the session's runtime with a bundle declaring a distinct
    # adapter id and assert the command reflects it.
    bundle = RuntimeRegistry::Bundle.new(
      runtime: "fake_runtime",
      air_adapter_name: "fake-adapter",
      config_post_processor_class: ClaudeMcpConfigPostProcessor
    )
    @session.stubs(:runtime).returns(bundle)

    captured_cmd = nil
    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    cmd_args = captured_cmd[1..]
    prepare_index = cmd_args.index("prepare")
    assert_not_nil prepare_index, "command should contain the prepare subcommand"
    assert_equal "fake-adapter", cmd_args[prepare_index + 1],
      "the argument after `prepare` must be the runtime bundle's air_adapter_name"
    refute_includes cmd_args, "claude",
      "the literal 'claude' must not appear — the adapter is registry-sourced"
  end

  test "prepare! does not mutate global ENV when injecting secrets" do
    test_key = "AIR_PREPARE_THREAD_SAFETY_TEST_KEY"
    ENV.delete(test_key)

    SecretsLoader.stub(:all, { test_key => "secret_value" }) do
      stub_air_subprocess(proc { |*args, **opts|
        # Verify secrets are NOT in global ENV during subprocess call
        assert_nil ENV[test_key], "SecretsLoader secrets must not be written to global ENV"
        # Verify secrets ARE in the env hash passed to capture3
        env_hash = args.first
        assert_equal "secret_value", env_hash[test_key]
        [ "", "", stub(success?: true, exitstatus: 0) ]
      }) do
        service = AirPrepareService.new(
          session: @session,
          working_directory: @working_dir,
          file_system: @mock_fs
        )
        service.prepare!
      end
    end

    assert_nil ENV[test_key], "ENV should remain clean after prepare!"
  end

  test "prepare! raises AirPrepareError on non-zero exit" do
    stub_air_subprocess(proc { |*args, **opts|
      [ "", "Error: config not found", stub(success?: false, exitstatus: 1) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )

      error = assert_raises(AirPrepareService::AirPrepareError) do
        service.prepare!
      end

      assert_match(/AIR prepare failed/, error.message)
      assert_match(/config not found/, error.message)
    end
  end

  test "run_air_prepare_command! retries a transient github.com clone failure then succeeds" do
    sleeps = []
    attempts = 0
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      attempts += 1
      if attempts == 1
        # The exact failure signature observed in the incident: AIR's catalog
        # clone hits a github.com ETIMEDOUT.
        [ "", "Error: Failed to clone tadasant/zimmer-catalog at ref \"HEAD\"\n  Error: spawnSync git ETIMEDOUT", stub(success?: false, exitstatus: 1) ]
      else
        [ "", "", stub(success?: true, exitstatus: 0) ]
      end
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs,
        sleeper: ->(s) { sleeps << s }
      )
      service.prepare! # must NOT raise — the retry succeeds
    end

    assert_equal 2, attempts, "should retry once after the transient ETIMEDOUT, then succeed"
    assert_equal [ 5 ], sleeps, "should back off once with the first delay before the successful retry"
  end

  test "run_air_prepare_command! retries with backoff then raises after exhausting transient failures" do
    sleeps = []
    attempts = 0
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      attempts += 1
      [ "", "Error: spawnSync git ETIMEDOUT", stub(success?: false, exitstatus: 1) ]
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs,
        sleeper: ->(s) { sleeps << s }
      )
      error = assert_raises(AirPrepareService::AirPrepareError) { service.prepare! }
      assert_match(/ETIMEDOUT/, error.message)
    end

    assert_equal 4, attempts, "should attempt once plus three retries (delays length + 1)"
    assert_equal [ 5, 10, 20 ], sleeps, "should back off with the full delay schedule before giving up"
  end

  test "run_air_prepare_command! does not retry a non-transient (deterministic config) failure" do
    sleeps = []
    attempts = 0
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      attempts += 1
      [ "", "Error: catalog entry 'foo' not found", stub(success?: false, exitstatus: 1) ]
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs,
        sleeper: ->(s) { sleeps << s }
      )
      assert_raises(AirPrepareService::AirPrepareError) { service.prepare! }
    end

    assert_equal 1, attempts, "a deterministic config error must fail fast, not retry"
    assert_empty sleeps, "no backoff should happen for a non-transient failure"
  end

  test "run_air_prepare_command! treats a watchdog TimeoutError as transient and retries" do
    sleeps = []
    attempts = 0
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      attempts += 1
      # First attempt hangs and is watchdog-killed; a hung air prepare is exactly
      # what wedges a session in `waiting`, so it must be retried.
      raise BoundedSubprocess::TimeoutError, "command timed out after 600s (process group killed): air prepare" if attempts == 1

      [ "", "", stub(success?: true, exitstatus: 0) ]
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs,
        sleeper: ->(s) { sleeps << s }
      )
      service.prepare! # must NOT raise — the retry succeeds
    end

    assert_equal 2, attempts, "a watchdog timeout should be retried"
    assert_equal [ 5 ], sleeps
  end

  test "run_air_prepare_command! refreshes the catalog cache and retries once when air prepare reports the root is not found, then succeeds" do
    # The incident: a session named a root merged to the catalog minutes earlier,
    # but this worker's AIR github cache was stale (CatalogRefreshJob runs
    # `air update` only every 15 min), so `air prepare --root <name>` failed with
    # "Root not found" even though the root was valid. The service must bust the
    # cache inline (a bounded `air update`) and retry rather than failing/paging.
    sleeps = []
    prepare_attempts = 0
    update_calls = 0
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      case command_array[1]
      when "prepare"
        prepare_attempts += 1
        if prepare_attempts == 1
          [ "", "Error: Root \"pulsemcp-asset-creation\" not found. Available roots: @local/foo", stub(success?: false, exitstatus: 1) ]
        else
          [ "", "", stub(success?: true, exitstatus: 0) ]
        end
      when "update"
        update_calls += 1
        [ "", "", stub(success?: true, exitstatus: 0) ]
      else
        raise "unexpected air command: #{command_array.inspect}"
      end
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs,
        sleeper: ->(s) { sleeps << s }
      )
      service.prepare! # must NOT raise — the cache refresh makes the root resolvable
    end

    assert_equal 2, prepare_attempts, "should retry air prepare once after the cache refresh"
    assert_equal 1, update_calls, "should bust the catalog cache exactly once via a bounded air update"
    assert_empty sleeps, "root-not-found refresh-and-retry should not use the transient backoff schedule"
  end

  test "run_air_prepare_command! raises RootResolutionError when the root is still not found after a catalog refresh" do
    # A genuinely bad root name: even after a fresh catalog the root is absent.
    # This must raise the graceful, non-paging RootResolutionError (not a plain
    # AirPrepareError that AgentSessionJob would re-raise into a paging crash),
    # and must only refresh the cache once (guarded by catalog_refreshed).
    prepare_attempts = 0
    update_calls = 0
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      case command_array[1]
      when "prepare"
        prepare_attempts += 1
        [ "", "Error: Root \"nonexistent-root\" not found. Available roots: @local/foo", stub(success?: false, exitstatus: 1) ]
      when "update"
        update_calls += 1
        [ "", "", stub(success?: true, exitstatus: 0) ]
      else
        raise "unexpected air command: #{command_array.inspect}"
      end
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      error = assert_raises(AirPrepareService::RootResolutionError) { service.prepare! }
      assert_match(/Root "nonexistent-root" not found/, error.message)
    end

    assert_equal 2, prepare_attempts, "should attempt prepare once, refresh, then retry exactly once"
    assert_equal 1, update_calls, "should refresh the cache exactly once even though the root stays unresolved"
  end

  test "run_air_prepare_command! still raises RootResolutionError when the catalog refresh itself fails" do
    # The cache refresh is best-effort: a failing `air update` must be swallowed
    # (logged at WARN) and must not mask the original root-not-found, which still
    # surfaces as a graceful RootResolutionError.
    prepare_attempts = 0
    update_calls = 0
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      case command_array[1]
      when "prepare"
        prepare_attempts += 1
        [ "", "Error: Root \"asset-root\" not found. Available roots: @local/foo", stub(success?: false, exitstatus: 1) ]
      when "update"
        update_calls += 1
        [ "", "fatal: unable to access github.com: Could not resolve host", stub(success?: false, exitstatus: 1) ]
      else
        raise "unexpected air command: #{command_array.inspect}"
      end
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      assert_raises(AirPrepareService::RootResolutionError) { service.prepare! }
    end

    assert_equal 2, prepare_attempts, "should still retry prepare once after a best-effort refresh attempt"
    assert_equal 1, update_calls, "should attempt the refresh exactly once"
  end

  test "run_air_prepare_command! raises SecretResolutionError on an unresolved variable without retrying" do
    # Verbatim stderr from Zimmer prod session 10163 (2026-07-09T17:31:22Z), which
    # selected the reframe-secrets-service-account MCP server whose artifact
    # interpolates ${REFRAME_MCP_PLATFORM_API_KEY} — a variable absent from Zimmer's
    # mcp_secrets credentials. A missing secret is deterministic and
    # operator-fixable, so it must raise the graceful SecretResolutionError
    # immediately: no backoff sleeps, no catalog refresh, no plain
    # AirPrepareError (which AgentSessionJob would re-raise into a paging crash).
    stderr = "Error: Unresolved variable in /home/rails/.zimmer/clones/" \
             "mcp-servers-main-1783618282-5a347481: ${REFRAME_MCP_PLATFORM_API_KEY}. " \
             "Ensure all variables are provided via environment or a secrets transform."
    prepare_attempts = 0
    update_calls = 0
    sleeps = []
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      case command_array[1]
      when "prepare"
        prepare_attempts += 1
        [ "", stderr, stub(success?: false, exitstatus: 1) ]
      when "update"
        update_calls += 1
        [ "", "", stub(success?: true, exitstatus: 0) ]
      else
        raise "unexpected air command: #{command_array.inspect}"
      end
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs,
        sleeper: ->(s) { sleeps << s }
      )
      error = assert_raises(AirPrepareService::SecretResolutionError) { service.prepare! }
      assert_equal [ "REFRAME_MCP_PLATFORM_API_KEY" ], error.variable_names
      assert_match(/Unresolved variable/, error.message)
    end

    assert_equal 1, prepare_attempts, "an unresolved variable must not be retried"
    assert_empty sleeps, "an unresolved variable must not use the transient backoff schedule"
    assert_equal 0, update_calls, "an unresolved variable must not trigger a catalog refresh"
  end

  test "run_air_prepare_command! captures every variable from AIR's pluralized unresolved message" do
    # air-sdk's unresolvedVarsMessage pluralizes and comma-joins when more than one
    # ${VAR} is unresolved, and does not constrain the variable name charset.
    stderr = "Error: Unresolved variables in /tmp/clone: ${REFRAME_MCP_PLATFORM_API_KEY}, " \
             "${some_lowercase_var}. Ensure all variables are provided via environment " \
             "or a secrets transform."
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      [ "", stderr, stub(success?: false, exitstatus: 1) ]
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      error = assert_raises(AirPrepareService::SecretResolutionError) { service.prepare! }
      assert_equal [ "REFRAME_MCP_PLATFORM_API_KEY", "some_lowercase_var" ], error.variable_names
    end
  end

  test "an unresolved variable is not misclassified as a transient air prepare failure" do
    # Guards the narrowness of the fix in both directions: the unresolved-variable
    # signature must not overlap the transient patterns (which would retry it), and
    # a generic AIR failure must NOT be downgraded to SecretResolutionError.
    service = AirPrepareService.new(
      session: @session,
      working_directory: @working_dir,
      file_system: @mock_fs
    )
    unresolved = "Error: Unresolved variable in /tmp/clone: ${FOO}. Ensure all variables " \
                 "are provided via environment or a secrets transform."

    refute service.send(:transient_air_failure?, unresolved)
    assert_equal [ "FOO" ], service.send(:unresolved_variable_names, unresolved)

    assert_empty service.send(:unresolved_variable_names, "Error: Root \"x\" not found.")
    assert_empty service.send(:unresolved_variable_names, "Error: something else broke")
    assert_empty service.send(:unresolved_variable_names, "fatal: unable to access github.com")

    # The prefix on one line must never bind to a ${…} on a later, unrelated line.
    assert_empty service.send(
      :unresolved_variable_names,
      "Unresolved variables in config scan\nsome error: ${HOME} was found"
    )

    # AIR prefixes real stderr with unrelated deprecation warnings; the signature
    # must still be found on its own line (this is the shape prod session 10163 hit).
    with_preamble = "warning: Plugin \"agent-transcript-capture\" declares its body inline.\n" \
                    "warning: Inline plugin bodies are deprecated as of v0.13.0.\n" \
                    "Error: Unresolved variables in /clones/x/agents/agent-roots/general-agent: " \
                    "${APPSIGNAL_API_KEY}, ${REMOTE_FS_SCREENSHOTS_GCS_PRIVATE_KEY}. Ensure all " \
                    "variables are provided via environment or a secrets transform."
    assert_equal [ "APPSIGNAL_API_KEY", "REMOTE_FS_SCREENSHOTS_GCS_PRIVATE_KEY" ],
      service.send(:unresolved_variable_names, with_preamble)
  end

  test "SecretResolutionError is a subclass of AirPrepareError" do
    assert AirPrepareService::SecretResolutionError < AirPrepareService::AirPrepareError
  end

  test "RootResolutionError is a subclass of AirPrepareError" do
    # Callers that rescue AirPrepareError broadly still catch root-resolution
    # failures; only AgentSessionJob's narrower rescue distinguishes them.
    assert AirPrepareService::RootResolutionError < AirPrepareService::AirPrepareError
  end

  test "run_air_prepare! bounds the air prepare exec with AIR_PREPARE_TIMEOUT_SECONDS" do
    captured_timeout = nil
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      captured_timeout = timeout
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }

    BoundedSubprocess.stub(:run, bounded) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    assert_equal AirPrepareService::AIR_PREPARE_TIMEOUT_SECONDS, captured_timeout,
      "the air prepare exec must be wrapped by the watchdog timeout so a hang can't wedge the session"
  end

  test "find_root_name prefers agent_root_key from metadata" do
    @session.update!(metadata: { "agent_root_key" => "pulsemcp-web-app" })

    service = AirPrepareService.new(
      session: @session,
      working_directory: @working_dir,
      file_system: @mock_fs
    )

    assert_equal "pulsemcp-web-app", service.send(:find_root_name)
  end

  test "find_root_name falls back to find_for_session" do
    @session.update!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      subdirectory: "agents/agent-orchestrator",
      metadata: {}
    )

    service = AirPrepareService.new(
      session: @session,
      working_directory: @working_dir,
      file_system: @mock_fs
    )

    assert_equal "agent-orchestrator", service.send(:find_root_name)
  end

  test "omits --root when no root name available" do
    @session.update!(
      git_root: "https://github.com/unknown/repo.git",
      subdirectory: nil,
      metadata: {}
    )
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    refute_includes captured_cmd, "--root"
  end

  test "omits --skill when no catalog skills" do
    @session.update!(catalog_skills: [])
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    refute_includes captured_cmd, "--skill"
  end

  test "prepare! passes --plugin when session has catalog_plugins" do
    @session.update!(catalog_plugins: [ "ci-workflow" ])
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    cmd_args = captured_cmd[1..]
    assert_includes cmd_args, "--plugin"
    assert_includes cmd_args, "ci-workflow"
  end

  test "prepare! expands selected plugin bundled MCP servers into runtime MCP selections" do
    @session.update!(
      mcp_servers: [ "remote-fs-screenshots" ],
      catalog_plugins: [ "figma-design-workflow" ]
    )
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    cmd_args = captured_cmd[1..]
    selected_mcp_servers = cmd_args.each_cons(2).filter_map { |flag, value| value if flag == "--mcp-server" }

    assert_includes selected_mcp_servers, "remote-fs-screenshots"
    assert_includes selected_mcp_servers, "figma"
    assert_includes selected_mcp_servers, "image-diff"
    assert_includes selected_mcp_servers, "svg-tracer"
    assert_includes selected_mcp_servers, "playwright-custom"
    assert_equal selected_mcp_servers.uniq, selected_mcp_servers
  end

  test "omits --plugin when no catalog plugins" do
    @session.update!(catalog_plugins: [])
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    refute_includes captured_cmd, "--plugin"
  end

  test "omits --mcp-server when no mcp servers" do
    @session.update!(mcp_servers: [])
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    refute_includes captured_cmd, "--mcp-server"
  end

  test "prepare! passes --hook when catalog_hooks present" do
    @session.update!(catalog_hooks: [ "git-push-ci-reminder" ])
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    assert_includes captured_cmd, "--hook"
    assert_includes captured_cmd, "git-push-ci-reminder"
  end

  test "omits --hook when no catalog hooks" do
    @session.update!(catalog_hooks: [])
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    refute_includes captured_cmd, "--hook"
  end

  test "prepare! repeats flags per value to support multiple IDs" do
    @session.update!(
      catalog_skills: [ "zimmer-run-tests", "zimmer-deploy-staging" ],
      mcp_servers: [ "playwright-custom", "context7" ]
    )
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    cmd_args = captured_cmd[1..]
    assert_equal 2, cmd_args.count("--skill"), "--skill should repeat once per skill ID"
    assert_includes cmd_args, "zimmer-run-tests"
    assert_includes cmd_args, "zimmer-deploy-staging"
    assert_equal 2, cmd_args.count("--mcp-server"), "--mcp-server should repeat once per server ID"
    assert_includes cmd_args, "playwright-custom"
    assert_includes cmd_args, "context7"
  end

  test "prepare! passes --no-subagent-merge to AIR CLI" do
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    assert_includes captured_cmd, "--no-subagent-merge"
  end

  test "prepare! passes --without-defaults to AIR CLI so root defaults are not layered on Zimmer's resolved session lists" do
    captured_cmd = nil

    stub_air_subprocess(proc { |*args, **opts|
      captured_cmd = args
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    assert_includes captured_cmd, "--without-defaults",
      "AIR v0.0.30+ adds skill/mcp/hook/plugin flags to root defaults instead of replacing them. " \
      "Without --without-defaults, defaults a user removed via the UI get silently re-added."
  end

  test "prepare! hands off to the runtime's config post-processor after AIR runs" do
    # prepare! delegates MCP-config post-processing to the runtime bundle's
    # config_post_processor_class. Verify the .mcp.json AIR wrote is processed
    # (e.g. npx --prefix injected) without AirPrepareService doing it inline.
    mcp_config_path = File.join(@working_dir, ".mcp.json")
    @mock_fs.write(mcp_config_path, JSON.pretty_generate(
      "mcpServers" => {
        "some-npx-server" => { "command" => "npx", "args" => [ "-y", "some-package" ], "env" => {} }
      }
    ))

    stub_air_subprocess(proc { |*args, **opts|
      [ "", "", stub(success?: true, exitstatus: 0) ]
    }) do
      service = AirPrepareService.new(
        session: @session,
        working_directory: @working_dir,
        file_system: @mock_fs
      )
      service.prepare!
    end

    args = JSON.parse(@mock_fs.read(mcp_config_path)).dig("mcpServers", "some-npx-server", "args")
    assert_includes args, "--prefix"
    assert_includes args, "/tmp"
  end

  test "ensure_baseline_mcp_config! delegates to the runtime's config post-processor" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    service = AirPrepareService.new(
      session: @session,
      working_directory: @working_dir,
      file_system: @mock_fs
    )
    service.ensure_baseline_mcp_config!

    mcp_config_path = File.join(@working_dir, ".mcp.json")
    assert @mock_fs.exists?(mcp_config_path), ".mcp.json should be created by the post-processor"
    self_server = JSON.parse(@mock_fs.read(mcp_config_path)).dig("mcpServers", "zimmer-self-session")
    assert_not_nil self_server, "Self-session Zimmer server should be injected via delegation"
    assert_equal "http", self_server["type"], "The self-session server is Zimmer's own native MCP endpoint"
    assert_includes self_server["url"], "/mcp?tool_groups=self_session"
    assert_equal [ "zimmer-self-session" ], service.injected_mcp_servers
  end

  private

  # Create a fake air binary that exits 0 — enough for air_binary_healthy? to pass.
  def create_fake_air_binary(air_dir)
    bin_dir = File.join(air_dir, "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    binary_path = File.join(bin_dir, "air")
    File.write(binary_path, "#!/bin/sh\necho '0.0.16'\n")
    File.chmod(0o755, binary_path)
  end

  # Check if a capture3 call is a health check (`air --version`).
  # Health check calls have the binary path as first arg and "--version" as second.
  def health_check_call?(args)
    args.length == 2 && args.last == "--version" && args.first.to_s.end_with?("air")
  end

  # Wrap a stub lambda so health check calls pass through to the real Open3.capture3.
  # All other calls go to the provided block.
  def stub_capture3_with_passthrough(&block)
    original = Open3.method(:capture3)
    ->(*args, **opts) {
      if health_check_call?(args)
        original.call(*args, **opts)
      else
        block.call(*args, **opts)
      end
    }
  end

  # Stub the two subprocess seams AirPrepareService uses:
  #   - Open3.capture3 → npm install + `air --version` health check (health checks
  #     pass through to the real fake binary).
  #   - BoundedSubprocess.run → the watchdog-wrapped `air prepare` exec.
  # Both route to +response+, invoked as response.call(env, *cmd) returning
  # [stdout, stderr, status], so existing assertions on the captured (env, *cmd)
  # shape work regardless of which seam ran the command.
  def stub_air_subprocess(response, &test)
    bounded = ->(command_array, timeout:, env: {}, cwd: nil) {
      response.call(env, *command_array)
    }
    Open3.stub(:capture3, stub_capture3_with_passthrough(&response)) do
      BoundedSubprocess.stub(:run, bounded, &test)
    end
  end
end
