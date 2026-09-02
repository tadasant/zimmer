# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

class WorkBacklog::AppendTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  test "appends by the band rules, stamps the writer, and keeps the rest in payload" do
    backlog_item(cost: "small", precedence: 6000)
    writer = sessions(:running)
    writer.update_columns(metadata: (writer.metadata || {}).merge("agent_root_key" => "issue-work-gate"))

    result = WorkBacklog::Append.call(
      append_attributes(key: "zimmer#7", "gate_session" => "https://zimmer.example.com/sessions/9",
                                        "notes" => "one line", "new_gate_field" => { "x" => 1 }),
      added_via: WorkBacklogItem::MCP, writing_session: writer
    )

    assert result.created?
    item = result.item
    assert_equal 5990, item.precedence
    assert_equal 2, result.position
    assert_equal false, result.respaced
    assert_equal writer.id, item.writing_session_id
    assert_equal "issue-work-gate", item.added_by, "added_by comes from the writing session's agent root"
    assert_equal WorkBacklogItem::MCP, item.added_via
    assert_equal Date.new(2026, 8, 29), item.decided_at
    assert_equal "https://zimmer.example.com/sessions/9", item.gate_session_url
    assert_equal "one line", item.notes
    assert_equal({ "x" => 1 }, item.payload["new_gate_field"])
    assert_equal({ "estimated_cost" => "small", "requirement_impact" => "medium" }, item.ratings)
    assert_not item.pinned
  end

  test "with no writing session, added_by falls back to the surface" do
    result = WorkBacklog::Append.call(append_attributes, added_via: WorkBacklogItem::API)
    assert_equal "api", result.item.added_by
    assert_nil result.item.writing_session_id
  end

  test "an explicit added_by wins" do
    result = WorkBacklog::Append.call(append_attributes("added_by" => "human"), added_via: WorkBacklogItem::API)
    assert_equal "human", result.item.added_by
  end

  test "idempotent on key among queued items" do
    first = WorkBacklog::Append.call(append_attributes(key: "zimmer#1"), added_via: WorkBacklogItem::MCP)
    second = WorkBacklog::Append.call(append_attributes(key: "zimmer#1", "title" => "different"), added_via: WorkBacklogItem::MCP)

    assert_not second.created?
    assert_equal first.item.id, second.item.id
    assert_equal 1, WorkBacklogItem.where(key: "zimmer#1").count
    assert_equal "Item zimmer#1", second.item.title, "the existing item is returned untouched"
  end

  test "a key that is only history does not block a fresh append" do
    old = backlog_item(key: "zimmer#1")
    old.remove!(reason: "issue_closed", by: "session:1")

    result = WorkBacklog::Append.call(append_attributes(key: "zimmer#1"), added_via: WorkBacklogItem::MCP)

    assert result.created?
    assert_equal 2, WorkBacklogItem.where(key: "zimmer#1").count
  end

  test "a human hand-placement is honoured verbatim and pinned" do
    result = WorkBacklog::Append.call(append_attributes, added_via: WorkBacklogItem::API,
                                                         placement: { "pinned" => "true", "precedence" => "9000" })

    assert result.item.pinned
    assert_equal 9000, result.item.precedence
  end

  test "a pin without a precedence is refused" do
    error = assert_raises(WorkBacklog::Append::InvalidItem) do
      WorkBacklog::Append.call(append_attributes, added_via: WorkBacklogItem::API, placement: { "pinned" => true })
    end
    assert_match(/explicit precedence/, error.message)
  end

  test "an unpinned placement is ignored: the rules decide" do
    result = WorkBacklog::Append.call(append_attributes, added_via: WorkBacklogItem::API,
                                                         placement: { "pinned" => false, "precedence" => 1 })
    assert_equal 6000, result.item.precedence
  end

  test "an invalid item is rejected with every reason and nothing is written" do
    error = assert_raises(WorkBacklog::Append::InvalidItem) do
      WorkBacklog::Append.call(append_attributes("estimated_cost" => "huge", "repo" => "nope"), added_via: WorkBacklogItem::API)
    end

    assert_match(/Estimated cost/, error.message)
    assert_match(/Repo/, error.message)
    assert_equal 0, WorkBacklogItem.count
  end

  test "a bad decided_at is rejected" do
    assert_raises(WorkBacklog::Append::InvalidItem) do
      WorkBacklog::Append.call(append_attributes("decided_at" => "yesterday"), added_via: WorkBacklogItem::API)
    end
  end

  test "an issueless item may come from a human with a prompt, and nobody else" do
    human = WorkBacklog::Append.call(
      append_attributes(key: "manual-x", "issue_url" => nil, "added_by" => "human", "prompt" => "Verbatim ask."),
      added_via: WorkBacklogItem::API
    )
    assert human.created?
    assert_equal "Verbatim ask.", human.item.prompt

    assert_raises(WorkBacklog::Append::InvalidItem) do
      WorkBacklog::Append.call(append_attributes(key: "manual-y", "issue_url" => nil, "prompt" => "x"), added_via: WorkBacklogItem::MCP)
    end
  end

  test "every append re-ranks the queue" do
    drifted = backlog_item(cost: "medium", precedence: 5500) # a medium sitting in the small band

    WorkBacklog::Append.call(append_attributes(cost: "small"), added_via: WorkBacklogItem::API)

    assert_equal 3000, drifted.reload.precedence
  end
end
