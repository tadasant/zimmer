# frozen_string_literal: true

require "test_helper"

class CliStatusServiceTest < ActiveSupport::TestCase
  setup do
    # Use memory store for cache tests (test env uses null_store by default)
    @original_cache = Rails.cache
    @test_cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache = @test_cache
  end

  teardown do
    # Restore original cache
    Rails.cache = @original_cache
  end

  # Deliberately public: `test "..."` is `define_method`, so it inherits the
  # enclosing default visibility, and minitest only collects PUBLIC `test_*`
  # methods. A `private` section anywhere in this class turns every test written
  # below it into a method that is defined, never run, and never reported.
  def credential_status(state)
    ClaudeCredentialHealth::Status.new(
      state: state, detail: "stubbed #{state}", owner_email: "operator@example.com", checked_at: Time.current
    )
  end

  # ==========================================================================
  # Class Constants
  # ==========================================================================

  test "defines CACHE_KEY constant" do
    assert_equal "cli_status_full_report", CliStatusService::CACHE_KEY
  end

  test "defines CACHE_TTL constant" do
    assert_equal 5.minutes, CliStatusService::CACHE_TTL
  end

  test "defines CLI_TOOLS with expected tools" do
    tools = CliStatusService::CLI_TOOLS
    assert tools.key?(:gh), "Should define :gh tool"
    assert tools.key?(:claude), "Should define :claude tool"
    assert tools.key?(:codex), "Should define :codex tool"
    assert tools.key?(:fly), "Should define :fly tool"
  end

  # ==========================================================================
  # Instance Methods
  # ==========================================================================

  test "full_status_report returns hash with expected structure" do
    service = CliStatusService.new
    report = service.full_status_report

    assert report.is_a?(Hash)
    assert report.key?(:tools)
    assert report.key?(:all_authenticated)
    assert report.key?(:unauthenticated_count)
    assert report.key?(:generated_at)
  end

  test "full_status_report includes all CLI tools" do
    service = CliStatusService.new
    report = service.full_status_report

    assert report[:tools].key?(:gh)
    assert report[:tools].key?(:claude)
    assert report[:tools].key?(:codex)
    assert report[:tools].key?(:fly)
  end

  test "each tool status includes required fields" do
    service = CliStatusService.new
    report = service.full_status_report

    report[:tools].each do |tool_name, status|
      assert status.key?(:name), "Tool #{tool_name} should have :name"
      assert status.key?(:installed), "Tool #{tool_name} should have :installed"
      assert status.key?(:authenticated), "Tool #{tool_name} should have :authenticated"
      assert status.key?(:install_instructions), "Tool #{tool_name} should have :install_instructions"
      assert status.key?(:auth_method), "Tool #{tool_name} should have :auth_method"
    end
  end

  test "generated_at is a Time object" do
    service = CliStatusService.new
    report = service.full_status_report

    assert report[:generated_at].is_a?(Time) || report[:generated_at].is_a?(ActiveSupport::TimeWithZone)
  end

  # ==========================================================================
  # Class Methods - Cached Access
  # ==========================================================================

  test "cached_report returns loading placeholder when cache is empty" do
    report = CliStatusService.cached_report

    assert report[:loading], "Should indicate loading state"
    assert_nil report[:generated_at], "Should have nil generated_at"
    assert_equal 0, report[:unauthenticated_count], "Should return 0 while loading"
  end

  test "cached_report returns cached data when available" do
    # Populate cache
    service = CliStatusService.new
    original_report = service.full_status_report
    Rails.cache.write(CliStatusService::CACHE_KEY, original_report, expires_in: CliStatusService::CACHE_TTL)

    # Read from cache
    cached = CliStatusService.cached_report

    assert_equal original_report[:tools].keys, cached[:tools].keys
    assert_equal original_report[:unauthenticated_count], cached[:unauthenticated_count]
    assert_not cached[:loading], "Should not be in loading state"
  end

  test "unauthenticated_count returns 0 when cache is empty" do
    count = CliStatusService.unauthenticated_count
    assert_equal 0, count, "Should return 0 while loading"
  end

  test "unauthenticated_count returns cached value when available" do
    # Create a report with specific unauthenticated count
    report = {
      tools: {},
      all_authenticated: false,
      unauthenticated_count: 2,
      generated_at: Time.current
    }
    Rails.cache.write(CliStatusService::CACHE_KEY, report, expires_in: CliStatusService::CACHE_TTL)

    count = CliStatusService.unauthenticated_count
    assert_equal 2, count
  end

  test "clear_cache removes cached report" do
    # Populate cache
    report = { tools: {}, unauthenticated_count: 1, generated_at: Time.current }
    Rails.cache.write(CliStatusService::CACHE_KEY, report, expires_in: CliStatusService::CACHE_TTL)

    # Verify cache is populated
    assert_not_nil Rails.cache.read(CliStatusService::CACHE_KEY)

    # Clear cache
    CliStatusService.clear_cache

    # Verify cache is empty
    assert_nil Rails.cache.read(CliStatusService::CACHE_KEY)
  end

  # ==========================================================================
  # Loading Placeholder
  # ==========================================================================

  test "loading_placeholder has loading flag set to true" do
    placeholder = CliStatusService.loading_placeholder

    assert placeholder[:loading]
    assert_nil placeholder[:generated_at]
    assert_nil placeholder[:all_authenticated]
    assert_equal 0, placeholder[:unauthenticated_count]
  end

  test "loading_placeholder includes all tools with loading state" do
    placeholder = CliStatusService.loading_placeholder

    CliStatusService::CLI_TOOLS.each_key do |tool|
      assert placeholder[:tools].key?(tool), "Should include #{tool}"
      assert placeholder[:tools][tool][:loading], "#{tool} should have loading: true"
      assert_nil placeholder[:tools][tool][:installed], "#{tool} installed should be nil"
      assert_nil placeholder[:tools][tool][:authenticated], "#{tool} authenticated should be nil"
    end
  end

  # ==========================================================================
  # Version Tracking
  # ==========================================================================

  test "each tool status includes version field" do
    service = CliStatusService.new
    report = service.full_status_report

    report[:tools].each do |tool_name, status|
      assert status.key?(:version), "Tool #{tool_name} should have :version key"
    end
  end

  test "loading_placeholder includes version field for all tools" do
    placeholder = CliStatusService.loading_placeholder

    CliStatusService::CLI_TOOLS.each_key do |tool|
      assert_nil placeholder[:tools][tool][:version], "#{tool} version should be nil in loading state"
    end
  end

  test "CLI_TOOLS defines check_version for all tools" do
    CliStatusService::CLI_TOOLS.each do |tool_name, config|
      assert config.key?(:check_version), "Tool #{tool_name} should have :check_version"
      assert config[:check_version].present?, "Tool #{tool_name} check_version should not be blank"
    end
  end

  # ==========================================================================
  # Auth Method Handling
  # ==========================================================================

  test "gh uses oauth auth method" do
    config = CliStatusService::CLI_TOOLS[:gh]
    assert_equal :oauth, config[:auth_method]
  end

  test "fly uses env_var auth method" do
    config = CliStatusService::CLI_TOOLS[:fly]
    assert_equal :env_var, config[:auth_method]
    assert_equal "FLY_IO_API_TOKEN", config[:env_var_name]
  end

  test "claude uses oauth auth method" do
    config = CliStatusService::CLI_TOOLS[:claude]
    assert_equal :oauth, config[:auth_method]
  end

  test "codex uses oauth auth method" do
    config = CliStatusService::CLI_TOOLS[:codex]
    assert_equal :oauth, config[:auth_method]
  end

  test "codex check_version invokes codex --version" do
    config = CliStatusService::CLI_TOOLS[:codex]
    assert_equal "codex --version", config[:check_version]
  end

  # ==========================================================================
  # No auth check may reach a billable path (#536)
  #
  # `claude whoami` was the auth check for months. `whoami` is not a Claude Code
  # subcommand, and `claude`'s usage line is `claude [options] [command]
  # [prompt]` — so the CLI took the word as a PROMPT and answered it with a full
  # agent turn, every two minutes on cron. `check_auth` only read the exit
  # status, so a successful inference call read as "authenticated".
  #
  # These are the guards against that shape coming back, for Claude Code and for
  # every sibling entry in the same hash.
  # ==========================================================================

  # Every subcommand `claude --help` lists, verified against CLI 2.1.258. Any
  # other first argument is a prompt, and a prompt costs money.
  CLAUDE_SUBCOMMANDS = %w[
    agents attach auth auto-mode doctor gateway import install logs mcp plugin
    plugins project respawn rm setup-token stop kill ultrareview update upgrade
  ].freeze

  # `gh`, `codex` and `fly` were checked directly: each rejects an unrecognized
  # subcommand with an error rather than taking it as a prompt, so their exposure
  # is smaller than Claude Code's. `pi` is an agent CLI and was not available to
  # check, which is the reason its entry is narrow rather than generous — an
  # allowlist that only names the subcommand actually in use is safe either way.
  NON_INFERENCE_SUBCOMMANDS = {
    "claude" => CLAUDE_SUBCOMMANDS,
    "gh" => %w[auth],
    "codex" => %w[login],
    "pi" => %w[auth],
    "fly" => %w[auth],
    "flyctl" => %w[auth]
  }.freeze

  # Covers every entry that CARRIES a shell auth check, not only the ones that run
  # one: `pi` and `fly` are `auth_method: :env_var`, so `check_tool` answers from
  # ENV and their `check_auth` string is inert until somebody flips them to
  # `:oauth`. That flip is exactly when an unnoticed bare prompt would go live.
  test "no shell auth check hands a bare prompt to its CLI" do
    CliStatusService::CLI_TOOLS.each do |tool_name, config|
      check = config[:check_auth]
      next if check.blank? || check.respond_to?(:call)

      # "fly auth whoami || flyctl auth whoami" is two commands, both of which count.
      check.split("||").each do |command|
        binary, subcommand, = command.strip.split
        allowed = NON_INFERENCE_SUBCOMMANDS[binary]

        assert allowed,
          "#{tool_name} auth check invokes unknown binary #{binary.inspect}; add it to " \
          "NON_INFERENCE_SUBCOMMANDS with the subcommands that make no model call"
        assert_includes allowed, subcommand,
          "#{tool_name} auth check #{command.strip.inspect} does not name a real subcommand of " \
          "#{binary}. For an agent CLI that means the argument is billed as a PROMPT (see #536)"
      end
    end
  end

  test "the Claude Code auth check is a callable and never shells out" do
    check = CliStatusService::CLI_TOOLS[:claude][:check_auth]

    assert check.respond_to?(:call),
      "The Claude Code auth check must not be a shell command: no `claude` invocation can answer " \
      "\"is Zimmer's stored credential usable\" — `claude auth status` only reads the environment " \
      "and reports Not logged in against ~/.claude/.credentials.json (#536)"
    refute_kind_of String, check
  end

  test "the Claude Code auth check reports authenticated when the credential is ok" do
    ClaudeCredentialHealth.stub(:status, credential_status(:ok)) do
      assert_equal true, CliStatusService::CLI_TOOLS[:claude][:check_auth].call
    end
  end

  test "the Claude Code auth check reports unauthenticated for every unusable credential state" do
    %i[absent mcp_only corrupt].each do |state|
      ClaudeCredentialHealth.stub(:status, credential_status(state)) do
        assert_equal false, CliStatusService::CLI_TOOLS[:claude][:check_auth].call,
          "credential state #{state} must not report as authenticated"
      end
    end
  end

  test "checking Claude Code auth makes no subprocess call at all" do
    service = CliStatusService.new
    spawned = []

    ClaudeCredentialHealth.stub(:status, credential_status(:ok)) do
      service.stub(:check_command, ->(command) { spawned << command; true }) do
        service.stub(:get_version, ->(command) { spawned << command; "2.1.258" }) do
          status = service.send(:check_tool, :claude)
          assert status[:authenticated]
        end
      end
    end

    # `which claude` and `claude --version` are the only commands that may run,
    # and neither reaches inference.
    assert_equal [ "which claude", "claude --version" ], spawned
  end

  test "a raising auth check reports unauthenticated instead of failing the refresh" do
    service = CliStatusService.new
    assert_equal false, service.send(:check_auth, -> { raise "boom" })
  end

  test "check_auth still reads the exit status of a shell command" do
    service = CliStatusService.new
    assert_equal true, service.send(:check_auth, "true")
    assert_equal false, service.send(:check_auth, "false")
  end

  # A callable in CLI_TOOLS is only safe because the report is built from an
  # explicit key list rather than from the config hash. If someone ever copies
  # `check_auth` through, `Rails.cache.write` blows up under Marshal and the JSON
  # surfaces (Api::V1::ClisController, get_system_health) blow up with it.
  test "the status report carries no callable into the cache or a JSON response" do
    [ CliStatusService.new.full_status_report, CliStatusService.loading_placeholder ].each do |report|
      report[:tools].each do |tool_name, status|
        status.each_value do |value|
          refute_respond_to value, :call, "#{tool_name} leaked a callable into the report"
        end
      end

      assert_nothing_raised { Marshal.dump(report) }
      assert_nothing_raised { JSON.generate(report.as_json) }
    end
  end
end
