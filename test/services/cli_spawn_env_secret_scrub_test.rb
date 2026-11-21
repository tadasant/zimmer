# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "open3"

# Zimmer's own secrets must not reach the agent CLI processes it spawns.
#
# Every runtime (claude_code, codex, pi) and the warm process pool build the child's
# environment through CliSpawnEnv#clear_inherited_env_vars. These tests seed the parent
# ENV with a sentinel for every secret the deployment hands Zimmer, spawn each runtime
# the way it spawns in production, and check what the child would receive — first in
# the env hash handed to Process.spawn, then in a real child process, because a nil in
# that hash only means "unset" if Process.spawn is the one reading it.
#
# The last group reads the deploy config: a new `env.secret` entry fails here until
# someone decides, in CliSpawnEnv, whether sessions inherit it.
class CliSpawnEnvSecretScrubTest < ActiveSupport::TestCase
  pin_delegated_cgroup_parent_absent

  SCRUBBED = CliSpawnEnv::SCRUBBED_SECRET_ENV_VARS.keys.freeze
  INHERITED = CliSpawnEnv::INHERITED_SECRET_ENV_VARS.keys.freeze
  REQUIRED_SCRUBS = %w[
    RAILS_MASTER_KEY SECRET_KEY_BASE API_KEYS OTEL_LOGS_EXPORTER_BEARER_TOKEN
    DATABASE_PASSWORD ZIMMER_OPERATOR_SSH_KEY ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON
    MERGE_ATTESTATION_SIGNING_KEY SENTRY_DSN_BACKEND
  ].freeze

  setup do
    @test_dir = Dir.mktmpdir("secret-scrub")
    @process_manager = MockProcessManager.new
    OperatorSshKeyProvisioner.stubs(:ensure!).returns(nil)
    @config_base = Dir.mktmpdir("claude-config-base")
    @original_config_dir = ENV["CLAUDE_SESSION_CONFIG_DIR"]
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = @config_base
    ClaudeTranscriptSource.stubs(:projects_root).returns(File.join(@config_base, "shared-projects"))

    @saved_env = (SCRUBBED + INHERITED).index_with { |name| ENV[name] }
    (SCRUBBED + INHERITED).each { |name| ENV[name] = sentinel(name) }
  end

  teardown do
    @saved_env.each { |name, value| ENV[name] = value }
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = @original_config_dir
    FileUtils.rm_rf(@test_dir)
    FileUtils.rm_rf(@config_base)
  end

  test "the secrets this program named are all scrubbed" do
    assert_empty REQUIRED_SCRUBS - SCRUBBED
  end

  test "no name is both scrubbed and inherited" do
    assert_empty SCRUBBED & INHERITED
  end

  test "claude_code: a cold spawn unsets every Zimmer secret" do
    adapter = claude_adapter
    adapter.send(:spawn_process, [ "claude", "test" ], working_dir: @test_dir)

    assert_scrubbed @process_manager.spawned_processes.last[:env]
  end

  test "claude_code: a warm-pool spawn unsets every Zimmer secret" do
    claude_adapter.spawn_warm(session_id: "warm-uuid", working_dir: @test_dir, mcp_config_path: nil,
                              model: "opus", stdout_path: File.join(@test_dir, "stdout.jsonl"),
                              env_file: File.join(@test_dir, "session.env"))

    assert_scrubbed @process_manager.spawned_processes.last[:env]
  end

  test "codex: a spawn unsets every Zimmer secret" do
    adapter = CodexRuntimeAdapter.new
    adapter.process_manager = @process_manager
    adapter.file_system = MockFileSystemAdapter.new
    adapter.execute(prompt: "go", session_id: "uuid", working_dir: @test_dir)

    assert_scrubbed @process_manager.spawned_processes.last[:env]
  end

  test "pi: a spawn unsets every Zimmer secret" do
    adapter = PiRuntimeAdapter.new
    file_system = MockFileSystemAdapter.new
    file_system.mkdir_p(@test_dir)
    adapter.process_manager = @process_manager
    adapter.file_system = file_system
    adapter.send(:spawn_process, [ "pi" ], working_dir: @test_dir)

    assert_scrubbed @process_manager.spawned_processes.last[:env]
  end

  # The hash above is only half the proof: nil means "unset" because Process.spawn says
  # so. Hand the hash Claude builds to a real child and read that child's environment.
  test "a real child process started with the spawn env sees none of the scrubbed secrets" do
    adapter = claude_adapter
    adapter.send(:spawn_process, [ "claude", "test" ], working_dir: @test_dir)
    env = @process_manager.spawned_processes.last[:env]

    output, status = Open3.capture2(env, "env")
    assert status.success?
    names = output.lines.map { |line| line.split("=", 2).first }

    assert_empty SCRUBBED & names, "a scrubbed secret reached the child process"
    assert_empty(SCRUBBED.select { |name| output.include?(sentinel(name)) },
      "a scrubbed secret's value reached the child process")
    INHERITED.each do |name|
      assert_includes output, "#{name}=#{sentinel(name)}", "#{name} is documented as inherited"
    end
  end

  # A session's own project may genuinely use one of these names for itself — its own
  # Rails app's SECRET_KEY_BASE, say. The clone's `.env` wins, as it does for every
  # other variable here.
  test "a clone's .env can still set a scrubbed name" do
    File.write(File.join(@test_dir, ".env"), "SECRET_KEY_BASE=the-clones-own-value\nSLACK_BOT_TOKEN=scoped-in\n")

    claude_adapter.send(:spawn_process, [ "claude", "test" ], working_dir: @test_dir)

    env = @process_manager.spawned_processes.last[:env]
    assert_equal "the-clones-own-value", env["SECRET_KEY_BASE"]
    # SessionSecretScope writes SLACK_BOT_TOKEN into the .env of a session given a Slack
    # server; scrubbing the worker's copy must not take that one away.
    assert_equal "scoped-in", env["SLACK_BOT_TOKEN"]
  end

  # --- the deploy config cannot add a secret sessions inherit by default ---------

  DEPLOY_CONFIGS = Dir[Rails.root.join("config/deploy*.yml")].freeze

  test "every deploy secret is either scrubbed from sessions or deliberately inherited" do
    assert_not_empty DEPLOY_CONFIGS

    undecided = deploy_secret_names - SCRUBBED - INHERITED
    assert_empty undecided,
      "#{undecided.join(', ')} reach the worker container as deploy secrets, and every agent " \
      "session inherits the worker's environment. Add each to CliSpawnEnv::SCRUBBED_SECRET_ENV_VARS, " \
      "or to INHERITED_SECRET_ENV_VARS with the reason a session needs it from its environment."
  end

  # Names in the clear that match the secret pattern but hold no secret, and why.
  CLEAR_NOT_SECRET = {
    "ZIMMER_SESSION_ENV_EXTRA_KEYS" => "a list of variable NAMES SessionSecretScope admits, not values"
  }.freeze

  test "every secret-named variable in a deploy env.clear is decided too" do
    named_like_secrets = deploy_clear_names.grep(TranscriptRedactor::SENSITIVE_KEY) - CLEAR_NOT_SECRET.keys

    undecided = named_like_secrets - SCRUBBED - INHERITED
    assert_empty undecided,
      "#{undecided.join(', ')} are named like secrets in a deploy env.clear. Decide them in " \
      "CliSpawnEnv, or rename them if they are not secret."
  end

  # Kamal's secrets files are where a new deploy secret starts. A name there that the
  # deploy configs never hand the container is harmless; a name both list is covered by
  # the env.secret test above. This keeps the two from drifting apart unnoticed.
  test "every name the Kamal secrets files map is either a registry login or a deploy secret" do
    kamal_names = Dir[Rails.root.join(".kamal/secrets*")].flat_map do |path|
      File.readlines(path).filter_map { |line| line[/\A([A-Z][A-Z0-9_]*)=/, 1] }
    end.uniq

    accessory_only = %w[POSTGRES_PASSWORD]
    stray = kamal_names - deploy_secret_names - %w[KAMAL_REGISTRY_USERNAME KAMAL_REGISTRY_PASSWORD] - accessory_only
    assert_empty stray, "#{stray.join(', ')} are mapped in .kamal/secrets* but no deploy config hands them out"
  end

  private

  def claude_adapter
    ClaudeCliAdapter.new.tap do |adapter|
      adapter.process_manager = @process_manager
      adapter.zimmer_session_id = 886
    end
  end

  def sentinel(name) = "sentinel-#{name.downcase}-must-not-leak"

  def assert_scrubbed(env)
    SCRUBBED.each do |name|
      assert env.key?(name), "#{name} must be in the spawn env as nil so Process.spawn unsets it"
      assert_nil env[name], "#{name} must be unset in the child"
    end
    INHERITED.each do |name|
      assert_not env.key?(name), "#{name} is documented as inherited, so the spawn env must leave it alone"
    end
  end

  def deploy_configs
    @deploy_configs ||= DEPLOY_CONFIGS.map do |path|
      YAML.safe_load(ERB.new(File.read(path)).result, aliases: true) || {}
    end
  end

  # Top-level env plus any per-role env: both land in the app containers. Accessory env
  # does not (its own container), so it is not read here.
  def container_envs
    deploy_configs.flat_map do |config|
      roles = config["servers"].is_a?(Hash) ? config["servers"].values.grep(Hash) : []
      [ config["env"], *roles.map { |role| role["env"] } ].grep(Hash)
    end
  end

  def deploy_secret_names
    container_envs.flat_map { |env| Array(env["secret"]) }.map { |name| name.to_s.split(":").first }.uniq
  end

  def deploy_clear_names
    container_envs.flat_map { |env| env["clear"].is_a?(Hash) ? env["clear"].keys : [] }.uniq
  end
end
