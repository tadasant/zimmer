# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# AgentSessionJob's two token broker seams: reporting what the broker did for a
# turn's prepare, and re-minting on the reused-clone path that runs no prepare.
class AgentSessionJobTokenBrokerTest < ActiveSupport::TestCase
  include TokenBrokerTestHelpers

  setup do
    turn_token_broker_on
    @session = create_session(status: :waiting, mcp_servers: [])
    @session.update_columns(mcp_servers: %w[image-diff granola])
    @log_buffer = LogBuffer.new(@session)
    @job = AgentSessionJob.new
  end

  def air_service_with(result)
    stub(brokered_token_result: result)
  end

  test "a failed mint is recorded as a degraded server with its cause, for the page and the agent's next prompt" do
    result = TokenBroker::MintResult.new(tokens: {}, failures: { "image-diff" => "no token broker grant exists for https://strad.example.com yet" })

    @log_buffer.stubs(:add)
    @log_buffer.expects(:add).with(regexp_matches(/'image-diff' is unavailable this turn because no token broker grant.*rather than given a broader credential/),
      has_entry(:level, "warning"))

    @job.send(:report_brokered_tokens, @session, air_service_with(result), @log_buffer)

    entry = @session.reload.degraded_mcp_servers.sole
    assert_equal "image-diff", entry["name"]
    assert_equal "token_broker_unavailable", entry["error"]
    assert_match(/no token broker grant exists/, entry["reason"])
  end

  test "a successful mint records nothing degraded" do
    result = TokenBroker::MintResult.new(tokens: { "image-diff" => "strad_oat_x" }, failures: {})

    @job.send(:report_brokered_tokens, @session, air_service_with(result), @log_buffer)

    assert_empty @session.reload.degraded_mcp_servers
  end

  test "the reused-clone path does nothing for a session with no brokered entry" do
    stub_mcp_catalog("image-diff" => static_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    AirPrepareService.expects(:new).never

    assert_nil @job.send(:remint_brokered_tokens_for_reused_clone, @session, Dir.tmpdir, @log_buffer)
  end

  test "the reused-clone path re-prepares, minting, for a session with a brokered entry" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    prepare = stub(prepare!: true, injected_mcp_servers: [], brokered_token_result: TokenBroker::MintResult.empty)
    AirPrepareService.expects(:new).with { |**kw| kw[:mint_brokered_tokens] == true && kw[:session] == @session }.returns(prepare)

    assert_equal :reprepared, @job.send(:remint_brokered_tokens_for_reused_clone, @session, Dir.tmpdir, @log_buffer)
  end

  # A brokered server carries no static credential, so naming the catalog's
  # variable would send the operator to the wrong secret.
  test "a rejected brokered token points at the grant, not at the static variable" do
    turn_token_broker_on
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"))
    text = rejected_credentials_log
    assert_match(/Token broker page/, text)
    assert_no_match(/static token, not OAuth/, text)
    assert_no_match(/STRAD_API_KEY/, text)
  end

  test "off, a rejected declaring server is explained as the static credential it carried" do
    turn_token_broker_off
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"))
    text = rejected_credentials_log
    assert_match(/static token, not OAuth/, text)
    assert_match(/STRAD_API_KEY/, text)
  end

  def rejected_credentials_log
    @session.update!(status: :running, custom_metadata: {
      "should_fail_session" => true, "mcp_failure_reason" => "MCP server(s) failed to connect: image-diff",
      "mcp_failed_servers" => [ { "name" => "image-diff", "status" => "failed", "error" => "Error POSTing to endpoint (HTTP 401): unauthorized" } ]
    })
    @job.process_manager = MockProcessManager.new
    @job.broadcast_service = BroadcastService.new
    log_buffer = LogBuffer.new(@session)
    @job.send(:check_and_handle_mcp_failure, @session, 12345, log_buffer)
    log_buffer.flush
    @session.logs.pluck(:content).join("\n")
  end
end
