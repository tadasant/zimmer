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
end
