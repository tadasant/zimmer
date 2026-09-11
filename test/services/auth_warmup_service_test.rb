# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests AuthWarmupService: the worker-boot warm-up that settles each runtime's
# DB-current login identity BEFORE GoodJob starts consuming jobs, closing the
# post-deploy "Not logged in / Please run /login" cold-start gap.
#
# Codex's canonical auth.json path is redirected to a temp dir so its disk write
# is observable and never touches the real filesystem. Claude writes nothing —
# its sessions carry their own credentials (issue #618) — so the assertion for it
# is that a usable account is current, which is what the spawn path now requires.
class AuthWarmupServiceTest < ActiveSupport::TestCase
  setup do
    @service = AuthWarmupService.new
    @tmpdir = Dir.mktmpdir

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
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @original_codex_home)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_auth_json_path)
  end

  test "warm_all settles the DB-current identity for every runtime" do
    # Precondition: this is a cold worker boot — no identity file on disk yet.
    refute File.exist?(CodexAuthProvider::AUTH_JSON_PATH)

    results = @service.warm_all

    # One Result per registered runtime, all successful.
    assert_equal RuntimeAuthProvider::RUNTIMES.sort, results.map(&:runtime).sort
    assert results.all?(&:ok?), "expected every runtime to warm successfully, got #{results.inspect}"

    # --- Claude: a usable account is current, and nothing was written to disk ---
    claude_current = claude_accounts(:primary)
    assert claude_current.reload.is_current?
    assert claude_current.claude_access_token.present?,
      "the spawn path exports this token; a current account without one fails the spawn"
    assert_equal [ "auth.json" ], Dir.children(@tmpdir),
      "Claude writes no credential file at all — only Codex's auth.json should appear"

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
    assert_equal claude_accounts(:primary), claude_result.account
  end

  test "a runtime that raises is captured in its Result and does not abort the others" do
    boom = RuntimeError.new("token endpoint unreachable")
    CodexAuthProvider.any_instance.stubs(:inject_for_session!).raises(boom)

    results = @service.warm_all

    codex_result = results.find { |r| r.runtime == CodexAuthProvider::RUNTIME }
    refute codex_result.ok?
    assert_equal boom, codex_result.error

    # The Claude runtime is unaffected and still warms.
    claude_result = results.find { |r| r.runtime == ClaudeAuthProvider::RUNTIME }
    assert claude_result.ok?
    assert_equal claude_accounts(:primary), claude_result.account
  end
end
