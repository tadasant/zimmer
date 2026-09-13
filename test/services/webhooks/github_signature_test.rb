# frozen_string_literal: true

require "test_helper"

class Webhooks::GithubSignatureTest < ActiveSupport::TestCase
  SECRET = "It's a Secret to Everybody"
  BODY = "Hello, World!"
  # The worked example in GitHub's "Validating webhook deliveries" documentation.
  DOCUMENTED = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"

  def verify(signature:, secret: SECRET, body: BODY)
    Webhooks::GithubSignature.verify(secret: secret, body: body, signature: signature)
  end

  test "signs the way GitHub documents" do
    assert_equal DOCUMENTED, Webhooks::GithubSignature.sign(secret: SECRET, body: BODY)
  end

  test "a signature over the body with the secret verifies" do
    assert_predicate verify(signature: DOCUMENTED), :valid?
  end

  test "a signature with the wrong secret does not verify" do
    result = verify(signature: DOCUMENTED, secret: "another secret")

    refute_predicate result, :valid?
    assert_equal "signature mismatch", result.reason
  end

  test "a body altered after signing does not verify" do
    refute_predicate verify(signature: DOCUMENTED, body: "Hello, World?"), :valid?
  end

  test "a missing signature does not verify" do
    assert_equal "missing X-Hub-Signature-256", verify(signature: nil).reason
  end

  test "a sha1 signature is not accepted" do
    sha1 = "sha1=#{OpenSSL::HMAC.hexdigest('SHA1', SECRET, BODY)}"

    assert_equal "X-Hub-Signature-256 is not a sha256= signature", verify(signature: sha1).reason
  end

  test "with no secret nothing verifies" do
    assert_equal "no webhook secret configured", verify(signature: DOCUMENTED, secret: nil).reason
  end
end
