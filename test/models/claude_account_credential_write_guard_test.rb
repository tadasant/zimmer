# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The guard that was missing on 2026-08-22: nothing stopped a stale DB copy from
# overwriting live filesystem credentials, so Zimmer destroyed a token that
# existed only on disk and neither store could recover it.
#
# See https://github.com/tadasant/zimmer/issues/618, hole 1.
class ClaudeAccountCredentialWriteGuardTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir
    @original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(@tmpdir, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@tmpdir, ".credentials.json"))

    @account = claude_accounts(:primary)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
  end

  # ---------------------------------------------------------------- helpers

  # Epoch milliseconds, the unit claudeAiOauth.expiresAt uses.
  def ms(time) = (time.to_f * 1000).to_i

  def credentials(access:, refresh:, expires_at:, **extra)
    { "claudeAiOauth" => { "accessToken" => access, "refreshToken" => refresh, "expiresAt" => expires_at }.merge(extra) }
  end

  def store_credentials!(account, blob)
    account.update!(oauth_config: (account.oauth_config || {}).merge("credentials_json" => blob))
  end

  def write_disk(blob)
    FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.pretty_generate(blob))
  end

  def disk = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))

  # ------------------------------------------------------------------ tests

  test "refuses to overwrite a live on-disk credential with an older stored copy, and captures it instead" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh-SPENT", expires_at: ms(1.hour.from_now)))
    write_disk(credentials(access: "cli-access", refresh: "cli-refresh-LIVE", expires_at: ms(8.hours.from_now)))

    assert @account.write_credentials_to_filesystem!

    assert_equal "cli-refresh-LIVE", disk.dig("claudeAiOauth", "refreshToken"),
      "the live on-disk refresh token must survive the write"
    assert_equal "cli-refresh-LIVE", @account.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken"),
      "the rescued pair must be captured into the DB, not merely left on disk"
  end

  test "writes the stored copy when it is the newer of the two" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh-FRESH", expires_at: ms(8.hours.from_now)))
    write_disk(credentials(access: "old-access", refresh: "old-refresh", expires_at: ms(1.hour.from_now)))

    assert @account.write_credentials_to_filesystem!
    assert_equal "db-refresh-FRESH", disk.dig("claudeAiOauth", "refreshToken")
  end

  test "does not rescue credentials the marker says belong to another account" do
    ClaudeAccount.write_credentials_owner_marker!(claude_accounts(:secondary).email)
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh", expires_at: ms(1.hour.from_now)))
    write_disk(credentials(access: "other-access", refresh: "other-refresh", expires_at: ms(8.hours.from_now)))

    assert @account.write_credentials_to_filesystem!
    assert_equal "db-refresh", disk.dig("claudeAiOauth", "refreshToken"),
      "overwriting another account's credentials is the caller's intent on a switch"
  end

  test "does not rescue a blanked on-disk credential — that is the corruption case, and rewriting it is the repair" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh", expires_at: ms(1.hour.from_now)))
    # The exact shape the CLI left behind: tokens blanked, metadata intact.
    write_disk(credentials(access: "", refresh: "", expires_at: 0, "subscriptionType" => "max", "scopes" => [ "user:inference" ]))

    assert @account.write_credentials_to_filesystem!
    assert_equal "db-refresh", disk.dig("claudeAiOauth", "refreshToken")
  end

  test "force: skips the guard so a freshly minted login is not discarded" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    store_credentials!(@account, credentials(access: "just-logged-in", refresh: "brand-new-chain", expires_at: ms(1.hour.from_now)))
    write_disk(credentials(access: "stale-access", refresh: "stale-refresh", expires_at: ms(8.hours.from_now)))

    assert @account.write_credentials_to_filesystem!(force: true)
    assert_equal "brand-new-chain", disk.dig("claudeAiOauth", "refreshToken")
  end

  test "an implausible stored expiry cannot win the comparison against a real one" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    # 9999999999999 ms decodes to the year 2286 — the value issue #618 hole 8
    # found in a production row, alongside 19- and 20-character tokens.
    store_credentials!(@account, credentials(access: "test_access_token_1", refresh: "test_refresh_token_1", expires_at: 9_999_999_999_999))
    write_disk(credentials(access: "real-access", refresh: "real-refresh", expires_at: ms(8.hours.from_now)))

    assert @account.write_credentials_to_filesystem!
    assert_equal "real-refresh", disk.dig("claudeAiOauth", "refreshToken"),
      "a year-2286 expiry is not evidence of freshness and must not beat a real credential"
  end

  test "the other writer's mcpOAuth block survives a rescue" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh", expires_at: ms(1.hour.from_now)))
    live = credentials(access: "cli-access", refresh: "cli-refresh", expires_at: ms(8.hours.from_now))
    live["mcpOAuth"] = { "server|hash" => { "serverName" => "server", "accessToken" => "mcp-token" } }
    write_disk(live)

    assert @account.write_credentials_to_filesystem!
    assert_equal "mcp-token", disk.dig("mcpOAuth", "server|hash", "accessToken")
  end

  test "still refuses to write an incomplete stored credential set" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    store_credentials!(@account, credentials(access: "db-access", refresh: "", expires_at: ms(1.hour.from_now)))
    write_disk(credentials(access: "cli-access", refresh: "cli-refresh", expires_at: ms(8.hours.from_now)))

    assert_not @account.write_credentials_to_filesystem!
    assert_equal "cli-refresh", disk.dig("claudeAiOauth", "refreshToken")
  end

  # ------------------------------------------------- the incident, end to end

  test "the 2026-08-22 sequence no longer destroys a credential" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)

    # 1. The CLI rotated on disk. Only the filesystem holds the live chain.
    write_disk(credentials(access: "live-access", refresh: "live-refresh", expires_at: ms(8.hours.from_now)))
    # 2. Zimmer's DB copy is the previous, now-spent pair.
    store_credentials!(@account, credentials(access: "spent-access", refresh: "spent-refresh", expires_at: ms(30.minutes.from_now)))

    # 3. Zimmer converges the filesystem, as ensure_active_account! does on every
    #    session spawn. This is the write that destroyed the credential.
    @account.write_credentials_to_filesystem!

    # The live chain still exists — in BOTH stores.
    assert_equal "live-refresh", disk.dig("claudeAiOauth", "refreshToken")
    assert_equal "live-refresh", @account.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
  end

  # ------------------------------------------------------ addendum B: identity

  # ------------------------------------------------------------- hole 6 signal

  test "sync_tokens_from_filesystem! reports why it declined" do
    assert_equal :absent, @account.sync_tokens_from_filesystem!

    ClaudeAccount.write_credentials_owner_marker!(claude_accounts(:secondary).email)
    write_disk(credentials(access: "a", refresh: "b", expires_at: ms(1.hour.from_now)))
    assert_equal :not_owner, @account.sync_tokens_from_filesystem!

    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    write_disk(credentials(access: "", refresh: "", expires_at: 0))
    assert_equal :corrupt, @account.sync_tokens_from_filesystem!

    write_disk(credentials(access: "fresh-access", refresh: "fresh-refresh", expires_at: ms(2.hours.from_now)))
    assert_equal :synced, @account.sync_tokens_from_filesystem!
    assert_equal "fresh-refresh", @account.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken")
  end
  # ------------------------------------------------- review findings, #618 PR

  test "declines the rescue when the marker and the container-local identity disagree" do
    # After a manual `claude /login` as somebody else the CLI rewrites the tokens
    # and the identity but not the marker, so the marker alone would attribute a
    # different subscription's credentials to this row.
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH,
      JSON.generate("oauthAccount" => { "emailAddress" => "someone-else@tadasant.com" }))
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh", expires_at: ms(1.hour.from_now)))
    write_disk(credentials(access: "other-access", refresh: "other-refresh", expires_at: ms(8.hours.from_now)))

    assert @account.write_credentials_to_filesystem!
    assert_equal "db-refresh", disk.dig("claudeAiOauth", "refreshToken")
    assert_equal "db-refresh", @account.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken"),
      "another account's tokens must never be grafted onto this row"
  end

  test "rescues when the identity file is absent, as it is after a container replacement" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    FileUtils.rm_f(ClaudeAuthProvider::CLAUDE_JSON_PATH)
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh", expires_at: ms(1.hour.from_now)))
    write_disk(credentials(access: "cli-access", refresh: "cli-refresh", expires_at: ms(8.hours.from_now)))

    assert @account.write_credentials_to_filesystem!
    assert_equal "cli-refresh", disk.dig("claudeAiOauth", "refreshToken")
  end

  test "the rescue decision itself never writes the DB" do
    # It runs inside ClaudeCredentialStore's host-global flock, which has no
    # timeout and is taken by every session's MCP credential write. A DB write
    # underneath it would put a row lock inside a file lock on one path
    # (#write_config!) and outside it on another (#refresh_token!) — a lock-order
    # inversion Postgres cannot see and cannot break. The capture is persisted by
    # #write_credentials_to_filesystem! after the lock releases; the test above
    # pins that it still lands.
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    store_credentials!(@account, credentials(access: "db-access", refresh: "db-refresh", expires_at: ms(1.hour.from_now)))
    live = credentials(access: "cli-access", refresh: "cli-refresh", expires_at: ms(8.hours.from_now))

    rescued = @account.send(:rescue_live_filesystem_credentials, live)

    assert_equal "cli-refresh", rescued.dig("claudeAiOauth", "refreshToken"), "the decision must still be to adopt the disk copy"
    assert_equal "db-refresh", @account.reload.oauth_config.dig("credentials_json", "claudeAiOauth", "refreshToken"),
      "deciding must not touch the DB while the host-global flock is held"
  end
end
