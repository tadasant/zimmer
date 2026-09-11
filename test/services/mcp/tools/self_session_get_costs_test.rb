# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::SelfSessionGetCostsTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @other = sessions(:archived)
    @tool = tool_for(@session)
  end

  # The connection an injected self-session server actually makes: it names the
  # session it was written for, and that is where the scope comes from.
  def tool_for(session)
    Mcp::Tools::SelfSessionGetCosts.new(
      context: Mcp::Context.new(tool_groups: "self_session", session_id: session&.id)
    )
  end

  def usage(**overrides)
    SessionTokenUsage.create!({
      request_id: "req_#{SecureRandom.hex(6)}",
      model: "claude-opus-5",
      agent_root: "zimmer-router",
      session_id: @session.id,
      called_at: 2.hours.ago,
      input_tokens: 100,
      output_tokens: 1_000,
      cache_read_tokens: 500_000,
      cache_creation_tokens: 200_000,
      cache_creation_1h_tokens: 200_000
    }.merge(overrides))
  end

  test "reports the calling session's spend with no arguments at all" do
    usage

    output = @tool.call({})

    assert_match "Session ##{@session.id}", output
    assert_match "Main thread", output
    assert_match "cache write", output
  end

  test "returns only the calling session's spend, never another session's" do
    usage(output_tokens: 1_000)
    usage(session_id: @other.id, output_tokens: 9_000_000, agent_root: "some-other-root")

    output = @tool.call({})

    mine = SessionTokenUsage.where(session_id: @session.id).totals
    theirs = SessionTokenUsage.where(session_id: @other.id).totals

    assert_operator theirs[:cost_usd], :>, mine[:cost_usd], "the other session must be the expensive one"
    assert_match format("$%.2f", mine[:cost_usd]), output
    assert_no_match(/#{Regexp.escape(format("$%.2f", theirs[:cost_usd]))}/, output)
    assert_no_match(/some-other-root/, output)
    assert_equal 1, output.scan(/API calls/).size
    assert_match "#{mine[:api_calls]} API calls", output
  end

  # The fleet-wide report is what this tool exists NOT to serve. There is no
  # argument that reaches it: omitting everything is the session's own report,
  # and the fleet headings never appear.
  test "refuses the fleet-wide form — no arguments means this session, not the deployment" do
    usage
    usage(session_id: @other.id, agent_root: "issue-work-gate")

    output = @tool.call({})

    assert_no_match(/## Token spend —/, output, "that is the fleet report's heading")
    assert_no_match(/### By agent root/, output)
    assert_no_match(/### Most expensive sessions/, output)
    assert_no_match(/Burn rates/, output)
    assert_no_match(/issue-work-gate/, output)
  end

  test "refuses the agent_root form even though the narrowed schema does not advertise it" do
    usage

    error = assert_raises(Mcp::ToolError) { @tool.call({ "agent_root" => "zimmer-router" }) }

    assert_match "cannot report on agent root `zimmer-router`", error.message
    assert_match "health", error.message, "the refusal should name where the fleet report lives"
  end

  test "refuses to report another session's spend when the connection names the caller" do
    usage(session_id: @other.id)

    error = assert_raises(Mcp::ToolError) { @tool.call({ "session_id" => @other.id }) }

    assert_match "belongs to session ##{@session.id}", error.message
    assert_match "##{@other.id}", error.message
  end

  test "an explicit session_id matching the caller is accepted" do
    usage

    output = @tool.call({ "session_id" => @session.id.to_s })

    assert_match "Session ##{@session.id}", output
  end

  # A human client on `?tool_groups=self_session` carries no session identity, so
  # there is nothing to scope to — and falling back to the fleet is exactly the
  # thing this tool must not do. It asks for a session instead.
  test "a connection that names no session refuses rather than widening to the fleet" do
    usage

    error = assert_raises(Mcp::ToolError) { tool_for(nil).call({}) }

    assert_match "Missing required parameter: session_id", error.message
  end

  test "honours the window, and says so when the session spent nothing inside it" do
    usage(called_at: 40.days.ago)

    assert_match "No spend recorded for session ##{@session.id}", @tool.call({ "days" => 7 })
    assert_match "Session ##{@session.id}", @tool.call({ "days" => 90 })
  end

  test "carries the same tool name as the fleet report it replaces" do
    assert_equal "get_costs", Mcp::Tools::SelfSessionGetCosts.tool_name
    assert_equal Mcp::Tools::GetCosts.tool_name, Mcp::Tools::SelfSessionGetCosts.tool_name
  end

  # The narrowing has to be legible from `tools/list` alone, or a model reads the
  # fleet tool's schema and plans a call that will be refused.
  test "the advertised schema offers the window and the caller's own id, and nothing wider" do
    properties = Mcp::Tools::SelfSessionGetCosts.input_schema.to_h[:properties] ||
                 Mcp::Tools::SelfSessionGetCosts.input_schema.to_h["properties"]

    assert_equal %w[days from to session_id].sort, properties.keys.map(&:to_s).sort
    assert_match "THIS session", Mcp::Tools::SelfSessionGetCosts.description
  end
end
