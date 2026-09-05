# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The spawn gate is the other place Zimmer asks a remote MCP server whether it
# requires OAuth, and the one that runs most often. It used to ask and throw the
# answer away; these tests pin that it now records it, and that recording is
# genuinely a side channel — the gate's own verdict is unchanged either way.
class AgentSessionJobOauthDeterminationTest < ActiveSupport::TestCase
  CREDENTIAL_KEY = "notion|feedfacefeedface"
  SERVER_URL = "https://mcp.notion.example.com/mcp"

  setup do
    @session = sessions(:active_session)
    @session.stubs(:user_selected_mcp_servers).returns([ "notion" ])

    injector = mock("injector")
    injector.stubs(:check_credentials_status).returns(
      "notion" => {
        server_url: SERVER_URL,
        credential_key: CREDENTIAL_KEY,
        has_credential: false,
        credential_valid: nil,
        refresh_failed: false,
        requires_reauth: nil,
        has_preregistered_oauth: false
      }
    )
    injector.stubs(:inject_credentials!).returns(nil)
    McpOauthCredentialInjector.stubs(:new).returns(injector)

    @job = AgentSessionJob.new
    @log_buffer = LogBuffer.new(@session)
  end

  test "an advertised requirement is recorded and still blocks the spawn" do
    stub_requirement(required: true, determination: McpServerOauthRequirement::ADVERTISED_REQUIRED)

    result = check!

    assert result[:blocked]
    assert_equal [ "notion" ], result[:missing_servers].map { |entry| entry[:server_name] }
    assert_equal McpServerOauthRequirement::ADVERTISED_REQUIRED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
  end

  test "an advertised absence is recorded and still does not block the spawn" do
    stub_requirement(required: false, determination: McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED)

    result = check!

    assert_not result[:blocked]
    assert_equal McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
  end

  # "We could not tell" and "the server said no" both leave the spawn unblocked,
  # which is why the log has to say which one happened — otherwise the two are
  # indistinguishable to whoever reads it later.
  test "an undetermined probe is recorded as undetermined and says so in the log" do
    stub_requirement(
      required: false,
      determination: McpServerOauthRequirement::UNDETERMINED,
      error: "execution expired"
    )

    result = check!

    assert_not result[:blocked]
    assert_equal McpServerOauthRequirement::UNDETERMINED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
    assert_match(/could not determine whether OAuth is required/, log_text)
    assert_no_match(/does not require OAuth/, log_text)
  end

  test "a probe that raises records undetermined without blocking the spawn" do
    McpOauthService.any_instance.stubs(:check_oauth_requirement).raises(StandardError, "boom")

    result = check!

    assert_not result[:blocked]
    assert_equal McpServerOauthRequirement::UNDETERMINED,
      McpServerOauthRequirement.determination_for(CREDENTIAL_KEY)
  end

  private

  def check!
    @job.send(:check_and_inject_oauth_credentials, @session, "/tmp/clone", @log_buffer)
  end

  def log_text
    @log_buffer.instance_variable_get(:@buffer).map { |entry| entry[:content] }.join("\n")
  end

  def stub_requirement(required:, determination:, error: nil)
    McpOauthService.any_instance.stubs(:check_oauth_requirement).returns(
      McpOauthService::OAuthRequirement.new(
        required: required, metadata: nil, error: error, determination: determination
      )
    )
  end
end
