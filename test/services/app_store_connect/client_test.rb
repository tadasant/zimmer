# frozen_string_literal: true

require "test_helper"

class AppStoreConnect::ClientTest < ActiveSupport::TestCase
  KEY = OpenSSL::PKey::EC.generate("prime256v1")

  def chain(values)
    SecretProviders::Chain.new([ SecretProviders::Env.new(values) ])
  end

  def full_env(pem = KEY.to_pem)
    { "TESTFLIGHT_ASC_ISSUER_ID" => "issuer-uuid", "TESTFLIGHT_ASC_KEY_ID" => "ABC123XYZ9", "TESTFLIGHT_ASC_KEY_P8" => pem }
  end

  def client(transport, now: Time.utc(2026, 10, 29, 12))
    credentials = AppStoreConnect::Client.credentials(chain: chain(full_env))
    AppStoreConnect::Client.new(credentials: credentials, transport: transport, clock: -> { now })
  end

  test "credentials are nil unless all three values resolve" do
    assert_nil AppStoreConnect::Client.credentials(chain: chain({}))
    assert_nil AppStoreConnect::Client.credentials(chain: chain(full_env.except("TESTFLIGHT_ASC_KEY_P8")))
    assert_nil AppStoreConnect::Client.credentials(chain: chain(full_env.merge("TESTFLIGHT_ASC_KEY_ID" => "  ")))
    refute_nil AppStoreConnect::Client.credentials(chain: chain(full_env))
  end

  test "the upload workflow's variable names are not read" do
    upload_names = { "APP_STORE_CONNECT_API_ISSUER_ID" => "i", "APP_STORE_CONNECT_API_KEY_ID" => "k", "APP_STORE_CONNECT_API_KEY_P8" => KEY.to_pem }

    assert_nil AppStoreConnect::Client.credentials(chain: chain(upload_names))
  end

  test "the private key is accepted as PEM, as PEM with escaped newlines, or as base64" do
    pem = KEY.to_pem

    [ pem, pem.gsub("\n", "\\n"), Base64.strict_encode64(pem) ].each do |form|
      credentials = AppStoreConnect::Client.credentials(chain: chain(full_env(form)))
      assert_equal pem.strip, credentials.private_key.strip
    end
  end

  test "signs an ES256 token App Store Connect accepts the shape of" do
    now = Time.utc(2026, 10, 29, 12)
    token = client(nil, now: now).token

    payload, header = JWT.decode(token, KEY, true, algorithm: "ES256", verify_expiration: false, aud: "appstoreconnect-v1", verify_aud: true)
    assert_equal "ES256", header["alg"]
    assert_equal "ABC123XYZ9", header["kid"]
    assert_equal "JWT", header["typ"]
    assert_equal "issuer-uuid", payload["iss"]
    assert_equal now.to_i, payload["iat"]
    assert_operator payload["exp"] - payload["iat"], :<=, 20.minutes.to_i, "Apple refuses a token living longer than 20 minutes"
  end

  test "get sends the bearer token and parses the document" do
    seen = nil
    transport = ->(uri, headers) { seen = [ uri, headers ]; [ 200, '{"data":[]}' ] }

    document = client(transport).get("/v1/apps", { "filter[bundleId]" => "com.tadasant.zimmer" })

    assert_equal({ "data" => [] }, document)
    uri, headers = seen
    assert_equal "api.appstoreconnect.apple.com", uri.host
    assert_equal "filter%5BbundleId%5D=com.tadasant.zimmer", uri.query
    assert_match(/\ABearer ey/, headers["Authorization"])
  end

  test "a full next-page URL is followed as given" do
    seen = nil
    transport = ->(uri, _headers) { seen = uri; [ 200, "{}" ] }

    client(transport).get("https://api.appstoreconnect.apple.com/v1/apps/1/betaFeedbackCrashSubmissions?cursor=abc")

    assert_equal "cursor=abc", seen.query
  end

  test "a network failure or a body that is not JSON is an Error, so the job has one class to rescue" do
    error = assert_raises(AppStoreConnect::Client::Error) { client(->(*) { raise OpenSSL::SSL::SSLError, "unexpected eof" }).get("/v1/apps") }
    assert_match(/OpenSSL::SSL::SSLError/, error.message)

    assert_raises(AppStoreConnect::Client::Error) { client(->(*) { raise Net::ReadTimeout }).get("/v1/apps") }
    assert_raises(AppStoreConnect::Client::Error) { client(->(*) { [ 200, "<html>" ] }).get("/v1/apps") }
  end

  test "a 404 is NotFound and any other failure is an Error naming Apple's error code, not the body" do
    assert_raises(AppStoreConnect::Client::NotFound) do
      client(->(*) { [ 404, "{}" ] }).get("/v1/betaFeedbackCrashSubmissions/x/crashLog")
    end

    body = { errors: [ { code: "NOT_AUTHORIZED", title: "Authentication credentials are missing or invalid.", detail: "secret-ish" } ] }.to_json
    error = assert_raises(AppStoreConnect::Client::Error) { client(->(*) { [ 401, body ] }).get("/v1/apps") }
    assert_equal 401, error.status
    assert_match(/NOT_AUTHORIZED/, error.message)
    refute_match(/secret-ish/, error.message)
  end
end
