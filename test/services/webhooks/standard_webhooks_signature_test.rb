# frozen_string_literal: true

require "test_helper"

class Webhooks::StandardWebhooksSignatureTest < ActiveSupport::TestCase
  Sig = Webhooks::StandardWebhooksSignature

  # The worked example the Standard Webhooks reference libraries test against, so a signature Zimmer
  # accepts is one an off-the-shelf signer (strad's) produces.
  VECTOR_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  VECTOR_ID = "msg_p5jXN8AQM9LWM0D4loKWxJek"
  VECTOR_TIMESTAMP = "1614265330"
  VECTOR_BODY = '{"test": 2432232314}'
  VECTOR_SIGNATURE = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

  def verify(signature: VECTOR_SIGNATURE, body: VECTOR_BODY, timestamp: VECTOR_TIMESTAMP, secret: VECTOR_SECRET, id: VECTOR_ID, now: Time.at(VECTOR_TIMESTAMP.to_i))
    Sig.verify(secret: secret, body: body, message_id: id, timestamp: timestamp, signature: signature, now: now)
  end

  test "the Standard Webhooks reference vector verifies, and signing reproduces it" do
    assert_predicate verify, :valid?
    assert_equal VECTOR_SIGNATURE, Sig.sign(secret: VECTOR_SECRET, body: VECTOR_BODY, message_id: VECTOR_ID, timestamp: VECTOR_TIMESTAMP)
  end

  test "any one signature of several verifies, as during a secret rotation, and v1a entries are skipped" do
    assert_predicate verify(signature: "v1a,c29tZXRoaW5n v1,bm90IGl0 #{VECTOR_SIGNATURE}"), :valid?
    assert_not_predicate verify(signature: "v1,bm90IGl0 v1a,#{VECTOR_SIGNATURE.delete_prefix('v1,')}"), :valid?
  end

  test "a changed byte of body, id or timestamp fails" do
    assert_equal "signature mismatch", verify(body: '{"test": 2432232315}').reason
    assert_equal "signature mismatch", verify(id: "msg_p5jXN8AQM9LWM0D4loKWxJeK").reason
    assert_equal "signature mismatch", verify(timestamp: "1614265331", now: Time.at(1614265331)).reason
  end

  test "a timestamp more than five minutes from now fails, in either direction" do
    assert_predicate verify(now: Time.at(VECTOR_TIMESTAMP.to_i + 300)), :valid?
    assert_match(/freshness window/, verify(now: Time.at(VECTOR_TIMESTAMP.to_i + 301)).reason)
    assert_match(/freshness window/, verify(now: Time.at(VECTOR_TIMESTAMP.to_i - 301)).reason)
  end

  test "missing or malformed headers, and a secret that is not whsec_ with 24 to 64 bytes, fail" do
    assert_match(/missing/, verify(signature: nil).reason)
    assert_match(/malformed webhook-id/, verify(id: "msg with space").reason)
    assert_match(/malformed webhook-timestamp/, verify(timestamp: "12a").reason)
    assert_match(/secret/, verify(secret: "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw").reason)
    assert_match(/secret/, verify(secret: "whsec_#{Base64.strict_encode64('x' * 23)}").reason)
  end

  test "generated secrets are whsec_ plus 32 random bytes, and differ" do
    a = Sig.generate_secret
    assert_match(/\Awhsec_[A-Za-z0-9+\/]+=*\z/, a)
    assert_equal 32, Sig.key_bytes(a).bytesize
    assert_not_equal a, Sig.generate_secret
  end
end
