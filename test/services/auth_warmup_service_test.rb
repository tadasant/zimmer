# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests AuthWarmupService: the worker-boot warm-up that writes each runtime's
# DB-current login identity to disk BEFORE GoodJob starts consuming jobs, closing
# the post-deploy "Not logged in / Please run /login" cold-start gap.
#
# Both runtimes' canonical credential paths are redirected to temp dirs so the
# warm-up's disk writes are observable and never touch the real filesystem.
class AuthWarmupServiceTest < ActiveSupport::TestCase
  setup do
    @service = AuthWarmupService.new
    @tmpdir = Dir.mktmpdir

    # --- Redirect Claude credential paths (identity, credentials, owner marker) ---
    @original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(@tmpdir, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@tmpdir, ".credentials.json"))

    # --- Redirect Codex auth.json path ---
    @original_codex_home = CodexAuthProvider::CODEX_HOME
    @original_auth_json_path = CodexAuthProvider::AUTH_JSON_PATH
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @tmpdir)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, File.join(@tmpdir, "auth.json"))

    # Avoid real quota API calls in the Claude activation path.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
        utilization_5h: 0.5, utilization_7d: 0.3, status_5h: "allowed", status_7d: "allowed",
        reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
      )
    )

    # Defensive: if any account were treated as expiring, the token-refresh probe
    # must not hit the network. Fixtures don't expire, so this is belt-and-suspenders.
    successful_refresh = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_refresh.stubs(:code).returns("200")
    successful_refresh.stubs(:body).returns({
      access_token: "stubbed-access-token",
      refresh_token: "stubbed-refresh-token",
      expires_in: 3600
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(successful_refresh)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @original_codex_home)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_auth_json_path)
  end

  test "warm_all writes the DB-current identity to disk for every runtime" do
    # Precondition: this is a cold worker boot — no identity files on disk yet.
    refute File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)
    refute File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    refute File.exist?(CodexAuthProvider::AUTH_JSON_PATH)

    results = @service.warm_all

    # One Result per registered runtime, all successful.
    assert_equal RuntimeAuthProvider::RUNTIMES.sort, results.map(&:runtime).sort
    assert results.all?(&:ok?), "expected every runtime to warm successfully, got #{results.inspect}"

    # --- Claude identity written for the DB-current account (fixture: primary) ---
    claude_current = claude_accounts(:primary)
    assert claude_current.is_current?
    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH), "~/.claude.json should be written on boot"
    assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH), "~/.claude/.credentials.json should be written on boot"
    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal claude_current.email, claude_json["oauthAccount"]

    # Shared owner marker (the #4183 invariant) is stamped to the warmed account.
    assert_equal claude_current.email, ClaudeAccount.credentials_owner_email

    # --- Codex identity written for the DB-current account (fixture: codex_primary) ---
    codex_current = claude_accounts(:codex_primary)
    assert codex_current.is_current?
    assert File.exist?(CodexAuthProvider::AUTH_JSON_PATH), "~/.codex/auth.json should be written on boot"
    auth_json = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
    assert_equal codex_current.codex_account_id, auth_json.dig("tokens", "account_id")
  end

  test "warm_all returns a per-runtime Result identifying the warmed account" do
    results = @service.warm_all

    claude_result = results.find { |r| r.runtime == ClaudeAuthProvider::RUNTIME }
    assert claude_result.ok?
    assert_equal claude_accounts(:primary), claude_result.account

    codex_result = results.find { |r| r.runtime == CodexAuthProvider::RUNTIME }
    assert codex_result.ok?
    assert_equal claude_accounts(:codex_primary), codex_result.account
  end

  test "a runtime with no available account is skipped, not fatal" do
    # Empty the Codex pool so its warm-up finds nothing to write.
    ClaudeAccount.for_runtime("codex").delete_all

    results = @service.warm_all

    codex_result = results.find { |r| r.runtime == CodexAuthProvider::RUNTIME }
    assert codex_result.no_account?
    refute codex_result.ok?
    assert_nil codex_result.account

    # Claude still warmed successfully — one runtime's empty pool can't block another.
    claude_result = results.find { |r| r.runtime == ClaudeAuthProvider::RUNTIME }
    assert claude_result.ok?
    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)
  end

  test "a runtime that raises is captured in its Result and does not abort the others" do
    boom = RuntimeError.new("token endpoint unreachable")
    CodexAuthProvider.any_instance.stubs(:inject_for_session!).raises(boom)

    results = @service.warm_all

    codex_result = results.find { |r| r.runtime == CodexAuthProvider::RUNTIME }
    refute codex_result.ok?
    assert_equal boom, codex_result.error

    # The Claude runtime is unaffected and still warms to disk.
    claude_result = results.find { |r| r.runtime == ClaudeAuthProvider::RUNTIME }
    assert claude_result.ok?
    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)
  end
end
