# frozen_string_literal: true

require "test_helper"

class ContextFeatureAttributorTest < ActiveSupport::TestCase
  GOAL = "The user has indicated the goal for this task is: ship the thing. " * 40
  HIERARCHY = "<session-hierarchy>\n#{"- #1 router\n" * 40}</session-hierarchy>"

  def user_line(text, uuid: SecureRandom.uuid, parent: nil, session_id: "s1")
    {
      "type" => "user", "uuid" => uuid, "parentUuid" => parent, "sessionId" => session_id,
      "message" => { "role" => "user", "content" => text }
    }
  end

  def tool_result_line(content, tool_use_id:, uuid: SecureRandom.uuid, parent: nil, session_id: "s1")
    {
      "type" => "user", "uuid" => uuid, "parentUuid" => parent, "sessionId" => session_id,
      "message" => { "role" => "user", "content" => [
        { "type" => "tool_result", "tool_use_id" => tool_use_id, "content" => content }
      ] }
    }
  end

  def assistant_line(request_id:, blocks:, uuid: SecureRandom.uuid, parent: nil, session_id: "s1",
                     input: 5, output: 1_000, cache_read: 50_000, cache_creation: 10_000)
    {
      "type" => "assistant", "uuid" => uuid, "parentUuid" => parent, "requestId" => request_id,
      "sessionId" => session_id, "isSidechain" => false,
      "message" => {
        "role" => "assistant", "model" => "claude-opus-5", "content" => blocks,
        "usage" => {
          "input_tokens" => input, "output_tokens" => output,
          "cache_read_input_tokens" => cache_read,
          "cache_creation_input_tokens" => cache_creation,
          "cache_creation" => { "ephemeral_5m_input_tokens" => 0, "ephemeral_1h_input_tokens" => cache_creation }
        }
      }
    }
  end

  def attribute(lines)
    attributor = ContextFeatureAttributor.new
    lines.each { |line| attributor.observe(line) }
    attributor.rows
  end

  def by_feature(rows)
    rows.group_by { |r| r[:feature] }.transform_values do |group|
      group.sum { |r| r[:input_tokens] + r[:cache_read_tokens] + r[:cache_creation_tokens] + r[:output_tokens] }
    end
  end

  test "the parts can never exceed the request's own totals" do
    # The whole honesty rule. An estimate that outran the real usage would let a
    # feature be blamed for money that was never spent.
    u = user_line("#{GOAL}\n#{HIERARCHY}\n" + ("filler " * 5_000))
    a = assistant_line(request_id: "req-1", parent: u["uuid"],
                       blocks: [ { "type" => "text", "text" => "ok" } ],
                       input: 1, output: 10, cache_read: 0, cache_creation: 100)

    rows = attribute([ u, a ])
    actual = 1 + 10 + 0 + 100
    assert_operator by_feature(rows).values.sum, :<=, actual
  end

  test "content that arrives this turn is charged to the cache WRITE, not the read" do
    # Cache position is the reason dollars and tokens rank differently. New content
    # is what gets written; the conversation so far is what gets read back.
    u = user_line(GOAL)
    a = assistant_line(request_id: "req-1", parent: u["uuid"],
                       blocks: [ { "type" => "text", "text" => "ok" } ],
                       cache_read: 0, cache_creation: 20_000)

    goal_row = attribute([ u, a ]).find { |r| r[:feature] == "goal" }
    assert goal_row, "the goal block should be detected"
    assert_operator goal_row[:cache_creation_tokens], :>, 0
    assert_equal 0, goal_row[:cache_read_tokens]
  end

  test "content carried from an earlier turn is charged to the cache READ" do
    u1 = user_line(GOAL)
    a1 = assistant_line(request_id: "req-1", parent: u1["uuid"],
                        blocks: [ { "type" => "text", "text" => "first" } ],
                        cache_read: 0, cache_creation: 20_000)
    u2 = user_line("next", parent: a1["uuid"])
    a2 = assistant_line(request_id: "req-2", parent: u2["uuid"],
                        blocks: [ { "type" => "text", "text" => "second" } ],
                        cache_read: 80_000, cache_creation: 500)

    rows = attribute([ u1, a1, u2, a2 ])
    goal_on_second = rows.find { |r| r[:feature] == "goal" && r[:request_id] == "req-2" }

    assert goal_on_second, "the goal is still in the prompt on turn two"
    assert_operator goal_on_second[:cache_read_tokens], :>, 0
    assert_equal 0, goal_on_second[:cache_creation_tokens],
      "a block already in the prefix is not re-written"
  end

  test "an MCP tool result is told apart from a built-in one by the call it answers" do
    a1 = assistant_line(request_id: "req-1", blocks: [
      { "type" => "tool_use", "id" => "call_mcp", "name" => "mcp__zimmer__get_session", "input" => { "id" => 1 } },
      { "type" => "tool_use", "id" => "call_bash", "name" => "Bash", "input" => { "command" => "ls" } }
    ])
    r1 = tool_result_line("m" * 4_000, tool_use_id: "call_mcp", parent: a1["uuid"])
    r2 = tool_result_line("b" * 4_000, tool_use_id: "call_bash", parent: r1["uuid"])
    a2 = assistant_line(request_id: "req-2", parent: r2["uuid"],
                        blocks: [ { "type" => "text", "text" => "done" } ],
                        cache_read: 0, cache_creation: 30_000)

    totals = by_feature(attribute([ a1, r1, r2, a2 ]))

    assert_operator totals["mcp_result"].to_i, :>, 0
    assert_operator totals["tool_result"].to_i, :>, 0
  end

  test "a skill body is attributed to skills rather than to the prompt" do
    u = user_line("Base directory for this skill: /x\n\n# Do The Thing\n" + ("instruction " * 2_000))
    a = assistant_line(request_id: "req-1", parent: u["uuid"],
                       blocks: [ { "type" => "text", "text" => "ok" } ],
                       cache_read: 0, cache_creation: 20_000)

    totals = by_feature(attribute([ u, a ]))

    assert_operator totals["skill_body"].to_i, :>, 0
    assert_nil totals["prompt"]
  end

  test "several Zimmer blocks in one turn are split rather than lumped together" do
    u = user_line("Do the work.\n\n#{GOAL}\n#{HIERARCHY}")
    a = assistant_line(request_id: "req-1", parent: u["uuid"],
                       blocks: [ { "type" => "text", "text" => "ok" } ],
                       cache_read: 0, cache_creation: 40_000)

    totals = by_feature(attribute([ u, a ]))

    assert_operator totals["goal"].to_i, :>, 0
    assert_operator totals["session_hierarchy"].to_i, :>, 0
    assert_operator totals["prompt"].to_i, :>, 0, "the real instruction is still its own line"
  end

  test "two conversations in one file do not pool their contexts" do
    # A subagent sidechain and the main thread live in the same transcript. If the
    # attributor treated them as one growing prompt, the subagent's first request
    # would be charged for everything the main thread had said.
    u1 = user_line(GOAL, session_id: "s1")
    a1 = assistant_line(request_id: "req-1", parent: u1["uuid"], session_id: "s1",
                        blocks: [ { "type" => "text", "text" => "main" } ],
                        cache_read: 0, cache_creation: 20_000)
    u2 = user_line("side task", session_id: "s1")
    a2 = assistant_line(request_id: "req-2", parent: u2["uuid"], session_id: "s1",
                        blocks: [ { "type" => "text", "text" => "side" } ],
                        cache_read: 90_000, cache_creation: 500)

    rows = attribute([ u1, a1, u2, a2 ])

    assert_nil rows.find { |r| r[:feature] == "goal" && r[:request_id] == "req-2" },
      "the second conversation never saw the first one's goal block"
  end

  test "a line with no usage object produces nothing rather than a zeroed row" do
    u = user_line(GOAL)
    line = assistant_line(request_id: "req-1", parent: u["uuid"], blocks: [])
    line["message"].delete("usage")

    assert_empty attribute([ u, line ])
  end

  test "extended thinking is measured by its signature, because the text is redacted" do
    # The harness writes `thinking: ""` and keeps only the signature. Counting the
    # signature is all that is recoverable; the reasoning itself lands in the
    # residual. This test pins the behaviour so a future reader knows it is
    # deliberate rather than a detector that quietly broke.
    a = assistant_line(request_id: "req-1", cache_read: 0, cache_creation: 5_000, blocks: [
      { "type" => "thinking", "thinking" => "", "signature" => "s" * 2_000 }
    ])
    a2 = assistant_line(request_id: "req-2", parent: a["uuid"], cache_read: 0, cache_creation: 5_000,
                        blocks: [ { "type" => "text", "text" => "ok" } ])

    assert_operator by_feature(attribute([ a, a2 ]))["thinking"].to_i, :>, 0
  end
end
