# frozen_string_literal: true

require "test_helper"

# Named API keys through the two surfaces that take them (tadasant/zimmer#46):
# the REST API's `X-API-Key` and the MCP endpoint's `Authorization: Bearer`.
#
# What this pins, per surface: an API_KEYS entry still works (the cutover), a
# minted key works and stamps last_used_at, the log names the key and never
# prints it, and a revoke refuses the very next request — same process, no
# restart.
class ApiKeyAuthenticationTest < ActionDispatch::IntegrationTest
  ENV_KEY = "legacy-env-key-for-cutover"

  setup do
    @original_env = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = ENV_KEY
  end

  teardown do
    @original_env.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = @original_env
  end

  test "an API_KEYS entry keeps authenticating the REST API, and the log names it" do
    entries = capture_log_entries do
      get api_v1_sessions_path, headers: { "X-API-Key" => ENV_KEY }
    end

    assert_response :success
    api_key = ApiKey.find_by!(token_digest: ApiKey.digest(ENV_KEY))
    assert_predicate api_key, :env?
    assert_not_nil api_key.last_used_at
    assert_logged entries, "INFO", "authenticated as #{api_key.name.inspect} (api_key_id=#{api_key.id}, source=env)"
    refute_key_logged entries, ENV_KEY
  end

  test "an API_KEYS entry keeps authenticating the MCP endpoint as a bearer token" do
    mcp_tools_list(bearer: ENV_KEY)

    assert_response :success
    assert JSON.parse(response.body).dig("result", "tools").any?
  end

  test "a minted key authenticates both surfaces, then a revoke refuses both on the next request" do
    api_key, token = ApiKey.mint!(name: "e2e client")

    entries = capture_log_entries do
      get api_v1_sessions_path, headers: { "X-API-Key" => token }
      assert_response :success

      mcp_tools_list(bearer: token)
      assert_response :success
    end

    assert_not_nil api_key.reload.last_used_at
    assert_logged entries, "INFO", "GET /api/v1/sessions authenticated as \"e2e client\""
    assert_logged entries, "INFO", "POST /mcp authenticated as \"e2e client\""
    refute_key_logged entries, token

    api_key.revoke!

    entries = capture_log_entries do
      get api_v1_sessions_path, headers: { "X-API-Key" => token }
      assert_response :unauthorized

      mcp_tools_list(bearer: token)
      assert_response :unauthorized
    end

    assert_logged entries, "WARN", "GET /api/v1/sessions refused from 127.0.0.1: \"e2e client\""
    assert_logged entries, "WARN", "POST /mcp refused from 127.0.0.1: \"e2e client\""
    refute_key_logged entries, token

    api_key.restore!
    get api_v1_sessions_path, headers: { "X-API-Key" => token }
    assert_response :success
  end

  test "revoking an API_KEYS entry refuses it while it is still in the variable" do
    get api_v1_sessions_path, headers: { "X-API-Key" => ENV_KEY }
    assert_response :success

    ApiKey.find_by!(token_digest: ApiKey.digest(ENV_KEY)).revoke!

    get api_v1_sessions_path, headers: { "X-API-Key" => ENV_KEY }
    assert_response :unauthorized
    assert_equal ENV_KEY, ENV[ApiKey::ENV_VAR]
  end

  test "an unknown key is refused with the same 401 and logged at INFO" do
    entries = capture_log_entries do
      get api_v1_sessions_path, headers: { "X-API-Key" => "never-issued" }
    end

    assert_response :unauthorized
    assert_equal "Invalid or missing API key", JSON.parse(response.body)["message"]
    assert_logged entries, "INFO", "refused from 127.0.0.1: unknown API key"
    refute_key_logged entries, "never-issued"
  end

  private

  def mcp_tools_list(bearer:)
    post "/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: {
        "Authorization" => "Bearer #{bearer}",
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream"
      }
  end

  def assert_logged(entries, severity, fragment)
    assert entries.any? { |logged_severity, message| logged_severity == severity && message.include?(fragment) },
      "expected a #{severity} line containing #{fragment.inspect}; got:\n#{entries.map { |e| e.join(' ') }.join("\n")}"
  end

  def refute_key_logged(entries, key)
    leaked = entries.select { |_severity, message| message.include?(key) }
    assert_empty leaked, "the key itself reached the log"
  end
end
