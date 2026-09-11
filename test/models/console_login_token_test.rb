# frozen_string_literal: true

require "test_helper"

# The agent-login primitive's row (tadasant/zimmer#220): minted once, exchanged once,
# revocable until then, and never holding its own secret.
class ConsoleLoginTokenTest < ActiveSupport::TestCase
  test "mint! stores only the digest, and the wire token names the row" do
    token, plaintext = ConsoleLoginToken.mint!(principal: " ci-playwright ")

    assert_match(/\Azlt_#{token.id}\.[0-9a-f]{64}\z/, plaintext)
    assert_equal "ci-playwright", token.principal
    assert_equal ConsoleLoginToken::CONSOLE_ROLE, token.role
    assert_predicate token, :active?
    assert_equal ConsoleLoginToken::DEFAULT_SESSION_TTL_SECONDS, token.session_ttl_seconds
    assert_in_delta ConsoleLoginToken::DEFAULT_TTL_SECONDS.seconds.from_now, token.expires_at, 5.seconds

    secret = plaintext.delete_prefix("zlt_#{token.id}.")
    assert_equal Digest::SHA256.hexdigest(secret), token.secret_digest
    assert_not_includes token.attributes.values.map(&:to_s), plaintext
    assert_not_includes token.attributes.values.map(&:to_s), secret
  end

  test "mint! refuses a blank principal, a control character, and an out-of-range session ttl" do
    assert_raises(ActiveRecord::RecordInvalid) { ConsoleLoginToken.mint!(principal: "  ") }
    assert_raises(ActiveRecord::RecordInvalid) { ConsoleLoginToken.mint!(principal: "ci\nplaywright") }
    assert_raises(ActiveRecord::RecordInvalid) { ConsoleLoginToken.mint!(principal: "ci", session_ttl_seconds: ConsoleLoginToken::SESSION_TTL_SECONDS.end + 1) }
    assert_raises(ArgumentError) { ConsoleLoginToken.mint!(principal: "ci", ttl_seconds: ConsoleLoginToken::TTL_SECONDS.end + 1) }
  end

  test "a token exchanges exactly once" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")

    first = ConsoleLoginToken.exchange!(plaintext, consumed_from_ip: "100.64.0.7")
    assert_predicate first, :exchanged?
    assert_predicate first.token, :consumed?
    assert_not_nil first.token.consumed_at
    assert_equal "100.64.0.7", first.token.consumed_from_ip

    second = ConsoleLoginToken.exchange!(plaintext)
    assert_not_predicate second, :exchanged?
    assert_equal :consumed, second.refusal
    assert_equal token.id, second.token.id
  end

  test "the exchange is one conditional UPDATE, so a stale copy of the row cannot win" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    stale = ConsoleLoginToken.find(token.id)

    # Consume behind the stale copy's back, then present the token again: the
    # WHERE status = 'active' is what refuses it, not anything the loader saw.
    assert_predicate ConsoleLoginToken.exchange!(plaintext), :exchanged?
    assert_predicate stale, :active?
    assert_equal :consumed, ConsoleLoginToken.exchange!(plaintext).refusal
    assert_equal 1, ConsoleLoginToken.where(id: token.id, status: ConsoleLoginToken::CONSUMED).count
  end

  test "a revoked, unconsumed token is refused, and revoke is idempotent" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")

    assert token.revoke!
    assert_predicate token, :revoked?
    assert_not_nil token.revoked_at
    assert_not token.revoke!, "a second revoke changes nothing"

    exchange = ConsoleLoginToken.exchange!(plaintext)
    assert_not_predicate exchange, :exchanged?
    assert_equal :revoked, exchange.refusal
  end

  test "revoke is a no-op on a consumed token" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    ConsoleLoginToken.exchange!(plaintext)

    assert_not token.revoke!
    assert_predicate token, :consumed?
    assert_nil token.revoked_at
  end

  test "an expired token is refused and stays active for the reaper" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci", ttl_seconds: 10)

    exchange = ConsoleLoginToken.exchange!(plaintext, now: 11.seconds.from_now)
    assert_not_predicate exchange, :exchanged?
    assert_equal :expired, exchange.refusal
    assert_predicate token.reload, :active?
    assert_nil token.consumed_at
  end

  test "a wrong secret, an unknown id and a malformed token are each refused without touching a row" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    wrong_secret = "zlt_#{token.id}.#{"0" * 64}"

    assert_equal :bad_secret, ConsoleLoginToken.exchange!(wrong_secret).refusal
    assert_equal :unknown, ConsoleLoginToken.exchange!("zlt_#{token.id + 1_000_000}.#{"0" * 64}").refusal
    assert_equal :malformed, ConsoleLoginToken.exchange!("not-a-token").refusal
    assert_equal :malformed, ConsoleLoginToken.exchange!(nil).refusal
    assert_equal :malformed, ConsoleLoginToken.exchange!("zlt_#{token.id}.#{"0" * 63}").refusal
    assert_predicate token.reload, :active?

    # The right one still works after all of that.
    assert_predicate ConsoleLoginToken.exchange!(plaintext), :exchanged?
  end

  test "a wrong secret is refused even when the row state would also refuse" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    ConsoleLoginToken.exchange!(plaintext)

    # The state (consumed) is only told to a holder of the right secret.
    assert_equal :bad_secret, ConsoleLoginToken.exchange!("zlt_#{token.id}.#{"0" * 64}").refusal
  end

  test "a non-String presented token is malformed, not an error" do
    assert_equal :malformed, ConsoleLoginToken.exchange!({ "a" => "b" }).refusal
    assert_equal :malformed, ConsoleLoginToken.exchange!(123).refusal
  end

  test "revoke_presented! kills a whole valid token and nothing else" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")

    assert_not ConsoleLoginToken.revoke_presented!("zlt_#{token.id}.#{"0" * 64}"), "a wrong secret revokes nothing"
    assert_not ConsoleLoginToken.revoke_presented!("garbage")
    assert_predicate token.reload, :active?

    assert ConsoleLoginToken.revoke_presented!(plaintext)
    assert_predicate token.reload, :revoked?
    assert_not ConsoleLoginToken.revoke_presented!(plaintext), "idempotent"
  end

  test "an exchange whose row vanishes mid-flight is refused as unknown rather than raising" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    ConsoleLoginToken.stub(:find_by, ->(**conditions) { conditions[:id] == token.id && !@looked_up ? (@looked_up = token) : nil }) do
      assert_equal :unknown, ConsoleLoginToken.exchange!(plaintext).refusal
    end
  end

  test "as_api_json never carries the digest" do
    token, _plaintext = ConsoleLoginToken.mint!(principal: "ci", session_ttl_seconds: 120)

    api = token.as_api_json
    assert_equal token.id, api[:id]
    assert_equal "active", api[:status]
    assert_nil api[:consumed_at]
    assert_not api.key?(:secret_digest)
    assert_not_includes api.values.map(&:to_s), token.secret_digest
  end

  test "reapable is rows expired more than RETENTION ago, whatever their status" do
    now = Time.current
    fresh, _t = ConsoleLoginToken.mint!(principal: "fresh", now: now)
    recently_expired, _t = ConsoleLoginToken.mint!(principal: "recent", now: now - 1.day)
    old_active, _t = ConsoleLoginToken.mint!(principal: "old-active", now: now - ConsoleLoginToken::RETENTION - 1.day)
    old_consumed, old_plaintext = ConsoleLoginToken.mint!(principal: "old-consumed", now: now - ConsoleLoginToken::RETENTION - 1.day)
    ConsoleLoginToken.exchange!(old_plaintext, now: now - ConsoleLoginToken::RETENTION - 1.day)

    assert_equal [ old_active.id, old_consumed.id ].sort, ConsoleLoginToken.reapable(now).pluck(:id).sort
    assert_not_includes ConsoleLoginToken.reapable(now).pluck(:id), fresh.id
    assert_not_includes ConsoleLoginToken.reapable(now).pluck(:id), recently_expired.id
  end

  test "enabled? reads the environment on every call" do
    original = ENV[ConsoleLoginToken::ENABLED_ENV]
    ENV.delete(ConsoleLoginToken::ENABLED_ENV)
    assert_not ConsoleLoginToken.enabled?
    ENV[ConsoleLoginToken::ENABLED_ENV] = "1"
    assert_not ConsoleLoginToken.enabled?, "only the literal \"true\" opens it"
    ENV[ConsoleLoginToken::ENABLED_ENV] = "true"
    assert ConsoleLoginToken.enabled?
  ensure
    original.nil? ? ENV.delete(ConsoleLoginToken::ENABLED_ENV) : ENV[ConsoleLoginToken::ENABLED_ENV] = original
  end
end
