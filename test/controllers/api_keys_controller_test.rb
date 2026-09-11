# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The API keys settings page (tadasant/zimmer#46): every route behind the operator
# credential, the new key shown exactly once, and revoke/restore.
class ApiKeysControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  PASSWORD_ENV = OperatorHttpBasicAuth::PASSWORD_ENV
  PASSWORD = "api-keys-page-test-password"
  ENV_KEY = "env-key-for-the-page"

  setup do
    @original_password = ENV[PASSWORD_ENV]
    @original_env = ENV[ApiKey::ENV_VAR]
    ENV[PASSWORD_ENV] = PASSWORD
    ENV[ApiKey::ENV_VAR] = ENV_KEY
    SelfSessionInjector.any_instance.stubs(:self_target).returns({ base_url: "http://localhost:3000", api_key: ENV_KEY })
  end

  teardown do
    restore_env(PASSWORD_ENV, @original_password)
    restore_env(ApiKey::ENV_VAR, @original_env)
  end

  # --- The gate ---

  test "every route refuses without the operator credential" do
    api_key, _token = ApiKey.mint!(name: "gated")

    [
      -> { get api_keys_path },
      -> { post api_keys_path, params: { api_key: { name: "sneaky" } } },
      -> { post revoke_api_key_path(api_key) },
      -> { post restore_api_key_path(api_key) }
    ].each do |request|
      request.call
      assert_response :unauthorized
      assert_match(/Basic realm="#{OperatorHttpBasicAuth::REALM}"/, response.headers["WWW-Authenticate"])
    end

    assert_not ApiKey.exists?(name: "sneaky")
    assert_not api_key.reload.revoked?
  end

  test "an API key is not the operator credential" do
    get api_keys_path, headers: { "X-API-Key" => ENV_KEY }

    assert_response :unauthorized
  end

  test "an unconfigured realm closes the page and says why, without a challenge" do
    ENV.delete(PASSWORD_ENV)

    get api_keys_path, headers: operator_headers

    assert_response :unauthorized
    assert_nil response.headers["WWW-Authenticate"]
    assert_includes response.body, "#{PASSWORD_ENV} is unset or blank"
  end

  test "a hover prefetch is refused without a challenge" do
    get api_keys_path, headers: { "X-Sec-Purpose" => "prefetch" }

    assert_response :unauthorized
    assert_nil response.headers["WWW-Authenticate"]
  end

  # --- The page ---

  test "the index lists API_KEYS entries before they are ever used, and marks the agent sessions' key" do
    get api_keys_path, headers: operator_headers

    assert_response :success
    api_key = ApiKey.find_by!(token_digest: ApiKey.digest(ENV_KEY))
    assert_select "##{ActionView::RecordIdentifier.dom_id(api_key)}" do
      assert_select "span", text: api_key.name
      assert_select "span", text: "Agent sessions use this key"
      assert_select "dd", text: /never/
    end
    assert_not_includes response.body, ENV_KEY
  end

  test "creating a key shows it once, uncached, and stores only its digest" do
    post api_keys_path, params: { api_key: { name: "laptop scripts" } }, headers: operator_headers

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    token = css_select("#minted-key input").first["value"]
    assert token.start_with?(ApiKey::MINTED_PREFIX)

    api_key = ApiKey.find_by!(name: "laptop scripts")
    assert_equal ApiKey.digest(token), api_key.token_digest
    assert_predicate api_key, :minted?

    get api_keys_path, headers: operator_headers
    assert_not_includes response.body, token
  end

  test "a key is minted with the grant the form chose, and the page says which it is" do
    post api_keys_path, params: { api_key: { name: "chrome on the laptop", grant: ApiKey::QUICK_ROUTER_GRANT } }, headers: operator_headers
    assert_response :success

    api_key = ApiKey.find_by!(name: "chrome on the laptop")
    assert_predicate api_key, :quick_router?
    assert_includes response.body, "Paste it into the Zimmer extension"

    get api_keys_path, headers: operator_headers
    assert_select "##{dom_id(api_key)}", text: /Quick Router only/
  end

  test "no grant mints a full-API key; an unknown one mints nothing" do
    post api_keys_path, params: { api_key: { name: "plain" } }, headers: operator_headers
    assert_equal ApiKey::API_GRANT, ApiKey.find_by!(name: "plain").grant

    assert_no_difference("ApiKey.count") do
      post api_keys_path, params: { api_key: { name: "tampered", grant: "everything" } }, headers: operator_headers
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Grant is not included in the list"
  end

  test "creating a key with a taken name re-renders with the error" do
    ApiKey.mint!(name: "taken")

    assert_no_difference -> { ApiKey.where(source: ApiKey::MINTED_SOURCE).count } do
      post api_keys_path, params: { api_key: { name: "Taken" } }, headers: operator_headers
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Name has already been taken"
    assert_select "#minted-key", count: 0
  end

  test "revoke and restore flip the key and log who did it at WARN" do
    api_key, _token = ApiKey.mint!(name: "flip me")

    entries = capture_log_entries do
      post revoke_api_key_path(api_key), headers: operator_headers
    end
    assert_redirected_to api_keys_path
    assert_predicate api_key.reload, :revoked?
    assert(entries.any? { |severity, message| severity == "WARN" && message.include?("revoked \"flip me\"") })

    post restore_api_key_path(api_key), headers: operator_headers
    assert_redirected_to api_keys_path
    assert_not api_key.reload.revoked?
  end

  test "a scalar api_key param is a validation error, not a 500" do
    post api_keys_path, params: { api_key: "not-a-hash" }, headers: operator_headers

    assert_response :unprocessable_entity
    assert_includes response.body, "Name can&#39;t be blank"
  end

  test "a create that loses to the unique index re-renders with the error" do
    ApiKey.stubs(:mint!).raises(ActiveRecord::RecordNotUnique, "duplicate key value")

    post api_keys_path, params: { api_key: { name: "double click" } }, headers: operator_headers

    assert_response :unprocessable_entity
    assert_includes response.body, "Name has already been taken"
  end

  test "the page is exempt from Turbo's snapshot cache, so a shown key cannot be restored" do
    post api_keys_path, params: { api_key: { name: "cached?" } }, headers: operator_headers

    assert_select "meta[name='turbo-cache-control'][content='no-cache']"
  end

  test "the writes need a CSRF token even with the operator credential" do
    api_key, _token = ApiKey.mint!(name: "csrf target")
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post api_keys_path, params: { api_key: { name: "forged" } }, headers: operator_headers
    assert_response :unprocessable_entity
    post revoke_api_key_path(api_key), headers: operator_headers
    assert_response :unprocessable_entity

    assert_not ApiKey.exists?(name: "forged")
    assert_not api_key.reload.revoked?
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "the settings page links here without prefetching" do
    get settings_path

    assert_response :success
    assert_select "a[href='#{api_keys_path}'][data-turbo-prefetch='false']", text: /Manage API keys/
  end

  private

  def operator_headers
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("supervisor", PASSWORD) }
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
