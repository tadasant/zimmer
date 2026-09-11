# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# "Can a Claude Code session authenticate right now?"
#
# The question used to be asked of a host-global credentials file, where
# corruption was detected 126 times an hour and acted on zero times
# (https://github.com/tadasant/zimmer/issues/618, hole 5). It is asked of the DB
# row a session is handed its token out of now — there is no file — so the three
# states are about that row, and there is no repair to dry-run.
class ClaudeCredentialHealthTest < ActiveSupport::TestCase
  setup do
    @account = claude_accounts(:primary)
    # `update_all` moves the rows, not the loaded instance — reload, or the
    # `is_current: true` the helpers write is a no-op against a stale attribute.
    ClaudeAccount.update_all(is_current: false)
    @account.reload
  end

  def store!(credentials_json)
    @account.update!(oauth_config: @account.oauth_config.merge("credentials_json" => credentials_json))
    @account.update!(is_current: true)
  end

  def complete
    { "claudeAiOauth" => { "accessToken" => "a" * 108, "refreshToken" => "r" * 108,
                           "expiresAt" => (8.hours.from_now.to_f * 1000).to_i } }
  end

  test "no current account is not a fault" do
    status = ClaudeCredentialHealth.status

    assert_equal :absent, status.state
    assert_not status.corrupt?
    assert_nil status.owner_email
    assert_match(/next session spawn selects one/, status.detail)
  end

  test "a complete token pair on the current account is ok, and names it" do
    store!(complete)

    status = ClaudeCredentialHealth.status

    assert status.ok?
    assert_equal @account.email, status.owner_email
    assert_match(/no credentials file is in play/, status.detail)
  end

  # The incident shape, relocated. Blank tokens on the row a session would be
  # spawned from means every one of those sessions is logged out, exactly as a
  # blanked file did — which is why it is the same state and not a new one.
  test "blanked tokens are corrupt, and the detail says what a human has to do" do
    store!("claudeAiOauth" => { "accessToken" => "", "refreshToken" => "",
                                "subscriptionType" => "max", "scopes" => [ "user:inference" ] })

    status = ClaudeCredentialHealth.status

    assert status.corrupt?
    assert_match(/logged out/, status.detail)
    assert_match(/Re-authenticate #{@account.email} from \/inference/, status.detail)
    assert_equal @account.email, status.owner_email
  end

  test "an access token with no refresh token is corrupt" do
    # A dead end: once that access token expires nothing can mint a new one, and
    # Zimmer is the only thing that refreshes now.
    store!("claudeAiOauth" => { "accessToken" => "a" * 108 })

    assert ClaudeCredentialHealth.status.corrupt?
  end

  test "an empty stored config on the current account is corrupt" do
    @account.update!(oauth_config: {}, is_current: true)

    assert ClaudeCredentialHealth.status.corrupt?
  end

  test "the states are exactly the three a DB row can be in" do
    # `:mcp_only` went with the file it described — a store holding an mcpOAuth
    # map and no subscription tokens was a state only a shared file could be in.
    assert_equal %i[ok absent corrupt], ClaudeCredentialHealth::STATES
  end

  test "the status read writes nothing, so it is safe on a GET" do
    store!(complete)
    before = @account.reload.updated_at

    ClaudeCredentialHealth.status

    assert_equal before, @account.reload.updated_at
  end

  test "there is no self-heal to call" do
    # A corrupt FILE could be rewritten from the DB. A corrupt row is the bottom
    # of the stack: only a human re-authenticating fixes it, and saying so beats
    # a repair that cannot work.
    refute ClaudeCredentialHealth.respond_to?(:self_heal!)
  end
end
