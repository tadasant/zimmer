# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Corruption used to be detected 126 times an hour and acted on zero times.
# See https://github.com/tadasant/zimmer/issues/618, hole 5.
class ClaudeCredentialHealthTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@tmpdir, ".credentials.json"))

    @account = claude_accounts(:primary)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
  end

  def write_disk(blob)
    FileUtils.mkdir_p(File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.pretty_generate(blob))
  end

  def blanked
    { "claudeAiOauth" => { "accessToken" => "", "refreshToken" => "", "expiresAt" => 0,
                           "subscriptionType" => "max", "scopes" => [ "user:inference" ] } }
  end

  def healthy
    { "claudeAiOauth" => { "accessToken" => "a" * 108, "refreshToken" => "r" * 108,
                           "expiresAt" => (8.hours.from_now.to_f * 1000).to_i } }
  end

  test "absent file is not a fault" do
    status = ClaudeCredentialHealth.status
    assert_equal :absent, status.state
    assert_not status.corrupt?
  end

  test "a file holding only mcpOAuth is not a fault" do
    write_disk("mcpOAuth" => { "server|hash" => { "accessToken" => "t" } })
    assert_equal :mcp_only, ClaudeCredentialHealth.status.state
  end

  test "a complete token pair is ok" do
    write_disk(healthy)
    assert ClaudeCredentialHealth.status.ok?
  end

  test "blanked tokens are corrupt, and the detail says so in words an operator can act on" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    write_disk(blanked)

    status = ClaudeCredentialHealth.status
    assert status.corrupt?
    assert_match(/blanked to empty strings/, status.detail)
    assert_match(/logged out/, status.detail)
    assert_equal @account.email, status.owner_email
  end

  test "self_heal! rewrites a corrupt file from the owner's stored credentials" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    @account.update!(oauth_config: @account.oauth_config.merge(
      "credentials_json" => { "claudeAiOauth" => { "accessToken" => "stored-access", "refreshToken" => "stored-refresh",
                                                   "expiresAt" => (8.hours.from_now.to_f * 1000).to_i } }
    ))
    write_disk(blanked)

    outcome, detail = ClaudeCredentialHealth.self_heal!

    assert_equal :healed, outcome, detail
    on_disk = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    assert_equal "stored-refresh", on_disk.dig("claudeAiOauth", "refreshToken")
    assert ClaudeCredentialHealth.status.ok?
  end

  test "self_heal! is a no-op on a healthy file" do
    write_disk(healthy)
    outcome, = ClaudeCredentialHealth.self_heal!
    assert_equal :skipped, outcome
  end

  test "self_heal! declines when the stored copy is broken too — only a human can fix that" do
    ClaudeAccount.write_credentials_owner_marker!(@account.email)
    @account.update!(oauth_config: @account.oauth_config.merge(
      "credentials_json" => { "claudeAiOauth" => { "accessToken" => "a", "refreshToken" => "" } }
    ))
    write_disk(blanked)

    outcome, detail = ClaudeCredentialHealth.self_heal!
    assert_equal :skipped, outcome
    assert_match(/only a human re-authentication can fix this/, detail)
  end

  test "self_heal! declines when nothing owns the credentials file" do
    write_disk(blanked)
    outcome, detail = ClaudeCredentialHealth.self_heal!
    assert_equal :skipped, outcome
    assert_match(/no account owns/, detail)
  end

  test "self_heal! declines when the marker is the unowned sentinel" do
    ClaudeAccount.write_credentials_owner_marker!(ClaudeAccount::UNOWNED_CREDENTIALS_MARKER)
    write_disk(blanked)

    outcome, detail = ClaudeCredentialHealth.self_heal!
    assert_equal :skipped, outcome
    assert_match(/unowned/, detail)
  end
end
