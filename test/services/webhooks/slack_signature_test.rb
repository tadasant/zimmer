# frozen_string_literal: true

require "test_helper"

class Webhooks::SlackSignatureTest < ActiveSupport::TestCase
  SECRET = "8f742231b10e8888abcd99yyyzzz85a5"
  BODY = '{"type":"event_callback","event_id":"Ev1"}'
  NOW = Time.zone.at(1_756_500_000)

  # Computed here with OpenSSL rather than with SlackSignature.sign, so the test does not
  # grade the code with its own answer.
  def slack_signature(body, timestamp, secret: SECRET)
    "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
  end

  def verify(body: BODY, timestamp: NOW.to_i.to_s, signature: slack_signature(BODY, NOW.to_i), secret: SECRET, now: NOW)
    Webhooks::SlackSignature.verify(secret: secret, body: body, timestamp: timestamp, signature: signature, now: now)
  end

  test "a correctly signed, fresh request verifies" do
    assert_predicate verify, :valid?
  end

  test "sign produces the header value Slack sends" do
    assert_equal slack_signature(BODY, NOW.to_i),
      Webhooks::SlackSignature.sign(secret: SECRET, body: BODY, timestamp: NOW.to_i)
  end

  test "a signature made with a different secret is rejected" do
    result = verify(signature: slack_signature(BODY, NOW.to_i, secret: "not-the-secret"))

    refute_predicate result, :valid?
    assert_equal "signature mismatch", result.reason
  end

  test "a body changed after signing is rejected" do
    refute_predicate verify(body: BODY.sub("Ev1", "Ev2")), :valid?
  end

  test "a signature over a different timestamp is rejected" do
    refute_predicate verify(signature: slack_signature(BODY, NOW.to_i - 1)), :valid?
  end

  test "a missing timestamp or signature is rejected" do
    assert_match(/missing/, verify(timestamp: nil).reason)
    assert_match(/missing/, verify(signature: "").reason)
  end

  test "a non-numeric timestamp is rejected before anything is hashed" do
    assert_match(/malformed/, verify(timestamp: "12abc").reason)
  end

  test "a correctly signed request older than the freshness window is rejected" do
    old = NOW.to_i - Webhooks::SlackSignature::FRESHNESS_WINDOW.to_i - 1
    result = verify(timestamp: old.to_s, signature: slack_signature(BODY, old))

    refute_predicate result, :valid?
    assert_match(/freshness window/, result.reason)
  end

  test "a request stamped too far in the future is rejected the same way" do
    ahead = NOW.to_i + Webhooks::SlackSignature::FRESHNESS_WINDOW.to_i + 1

    refute_predicate verify(timestamp: ahead.to_s, signature: slack_signature(BODY, ahead)), :valid?
  end

  test "exactly at the edge of the window still verifies" do
    edge = NOW.to_i - Webhooks::SlackSignature::FRESHNESS_WINDOW.to_i

    assert_predicate verify(timestamp: edge.to_s, signature: slack_signature(BODY, edge)), :valid?
  end

  test "no secret verifies nothing, whatever the request carries" do
    result = verify(secret: nil)

    refute_predicate result, :valid?
    assert_match(/no signing secret/, result.reason)
  end
end
