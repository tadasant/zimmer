# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# McpOauthProbe is one of the two places Zimmer actually asks a remote MCP server
# whether it requires OAuth. It used to ask and throw the answer away, leaving
# every surface that cannot probe to assume a remote server might need OAuth.
# These tests pin the recording, which is what turns that assumption into a fact.
class McpOauthProbeTest < ActiveSupport::TestCase
  CREDENTIAL_KEY = "notion|deadbeefdeadbeef"
  SERVER_URL = "https://mcp.notion.example.com/mcp"

  setup do
    @session = sessions(:active_session)
    @session.stubs(:user_selected_mcp_servers).returns([ "notion" ])
    @session.stubs(:metadata).returns({ "working_directory" => "/tmp/clone" })

    injector = mock("injector")
    injector.stubs(:check_credentials_status).returns(
      "notion" => {
        server_url: SERVER_URL,
        credential_key: CREDENTIAL_KEY,
        has_credential: false,
        credential_valid: nil,
        requires_reauth: nil,
        has_preregistered_oauth: false
      }
    )
    McpOauthCredentialInjector.stubs(:new).returns(injector)
  end

  test "records an advertised OAuth requirement and still reports the server as needing it" do
    needing = McpOauthProbe.new(@session, oauth_service: fake_oauth_service(
      required: true, determination: McpServerOauthRequirement::ADVERTISED_REQUIRED
    )).servers_needing_oauth

    assert_equal [ "notion" ], needing.map { |entry| entry[:server_name] }
    assert_equal McpServerOauthRequirement::ADVERTISED_REQUIRED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
  end

  test "records an advertised absence of an OAuth requirement" do
    needing = McpOauthProbe.new(@session, oauth_service: fake_oauth_service(
      required: false, determination: McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED
    )).servers_needing_oauth

    assert_empty needing
    assert_equal McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
  end

  # A probe that could not get an answer must record that it could not, rather
  # than leaving a stale "no" in place or writing one.
  test "records undetermined when the probe cannot tell" do
    needing = McpOauthProbe.new(@session, oauth_service: fake_oauth_service(
      required: false, determination: McpServerOauthRequirement::UNDETERMINED, error: "connection refused"
    )).servers_needing_oauth

    assert_empty needing
    record = McpServerOauthRequirement.for_credential_key(CREDENTIAL_KEY).first
    assert_equal McpServerOauthRequirement::UNDETERMINED, record.determination
    assert_equal "connection refused", record.detail
  end

  test "records undetermined when the probe raises" do
    service = Object.new
    service.define_singleton_method(:check_oauth_requirement) { |*, **| raise "boom" }

    needing = McpOauthProbe.new(@session, oauth_service: service).servers_needing_oauth

    assert_empty needing
    assert_equal McpServerOauthRequirement::UNDETERMINED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
  end

  # Spending the budget means we never asked, which is not the same as asking and
  # not being able to tell. Nothing is recorded, so an earlier real answer stands.
  test "an exhausted budget records nothing and leaves an earlier answer standing" do
    McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: CREDENTIAL_KEY,
      determination: McpServerOauthRequirement::ADVERTISED_REQUIRED
    )
    service = Object.new
    service.define_singleton_method(:check_oauth_requirement) { |*, **| flunk("should not have probed") }

    needing = McpOauthProbe.new(@session, oauth_service: service, budget_seconds: -1).servers_needing_oauth

    assert_empty needing
    assert_equal McpServerOauthRequirement::ADVERTISED_REQUIRED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
  end

  private

  def fake_oauth_service(required:, determination:, error: nil)
    requirement = McpOauthService::OAuthRequirement.new(
      required: required, metadata: nil, error: error, determination: determination
    )
    service = Object.new
    service.define_singleton_method(:check_oauth_requirement) { |*, **| requirement }
    service
  end
end
