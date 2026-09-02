# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The groomer's pull, and the Start it is built on.
class WorkBacklog::PullTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  setup do
    @groomer = sessions(:running)
    @groomer.update_columns(precedence: 100, scheduling_class: "spot", genesis: "schedule")
  end

  test "starts the top N as spot zimmer-router sessions, records them, and carries the rank forward" do
    first = backlog_item(key: "zimmer#1", cost: "small", precedence: 6000)
    second = backlog_item(key: "zimmer#2", cost: "small", precedence: 5990)
    third = backlog_item(key: "zimmer#3", cost: "medium", precedence: 3000)

    result = assert_difference("Session.count", 2) { WorkBacklog::Pull.call(count: 2, acting_session: @groomer) }

    assert_equal [ "zimmer#1", "zimmer#2" ], result.started.map { |s| s.item.key }
    assert_empty result.removed

    session = result.started.first.session
    assert_equal "zimmer-router", session.metadata["agent_root_key"]
    assert_equal WorkBacklog::Start::GOAL, session.goal
    assert_equal "spot", session.scheduling_class
    assert_equal @groomer.id, session.parent_session_id
    assert_equal "https://github.com/tadasant/zimmer/issues/1\n\nPlease implement this.", session.prompt
    assert_equal "Implement zimmer#1 (Item zimmer#1)", session.title
    assert_equal "work-backlog", session.custom_metadata["spawned_by"]
    assert_equal "zimmer#1", session.custom_metadata["work_backlog_key"]
    assert_equal first.id, session.custom_metadata["work_backlog_item_id"]
    assert_not session.metadata.key?("auto_generated_title"), "the groomer's title must not be overwritten by inference"

    # <groomer precedence> + (pull_count − n + 1): 100 + 2 for the top item, 100 + 1 for the next.
    assert_equal 102, result.started[0].session.precedence
    assert_equal 101, result.started[1].session.precedence

    first.reload
    assert first.started?
    assert_equal session.id, first.started_session_id
    assert_equal @groomer.id, first.started_by_session_id
    assert first.started_at.present?
    assert second.reload.started?
    assert third.reload.queued?
    assert_equal [ "zimmer#3" ], queued_keys
  end

  test "starts exactly the keys named, in that order" do
    backlog_item(key: "zimmer#1", precedence: 6000)
    b = backlog_item(key: "zimmer#2", precedence: 5990)
    c = backlog_item(key: "zimmer#3", precedence: 5980)

    result = WorkBacklog::Pull.call(keys: [ "zimmer#3", "zimmer#2" ], acting_session: @groomer)

    assert_equal [ c.id, b.id ], result.started.map { |s| s.item.id }
    assert_equal [ "zimmer#1" ], queued_keys
  end

  test "a key that is not queued fails the whole pull and spawns nothing" do
    backlog_item(key: "zimmer#1")

    assert_no_difference("Session.count") do
      error = assert_raises(WorkBacklog::Pull::InvalidPull) { WorkBacklog::Pull.call(keys: [ "zimmer#1", "zimmer#404" ]) }
      assert_match(/not queued: zimmer#404/, error.message)
    end
    assert WorkBacklogItem.find_by(key: "zimmer#1").queued?
  end

  test "dead items are removed with a mechanical reason and the puller recorded" do
    backlog_item(key: "zimmer#1", precedence: 6000)
    dead = backlog_item(key: "zimmer#2", precedence: 5990)

    result = WorkBacklog::Pull.call(count: 1, dead: [ { "key" => "zimmer#2", "reason" => "issue_closed" } ],
                                    acting_session: @groomer)

    assert_equal [ "zimmer#1" ], result.started.map { |s| s.item.key }
    assert_equal [ "zimmer#2" ], result.removed.map { |r| r.item.key }
    dead.reload
    assert dead.removed?
    assert_equal "issue_closed", dead.removal_reason
    assert_equal "session:#{@groomer.id}", dead.removed_by
  end

  test "a removal reason outside the mechanical vocabulary is refused: that is a human's call" do
    backlog_item(key: "zimmer#1")

    error = assert_raises(WorkBacklog::Pull::InvalidPull) do
      WorkBacklog::Pull.call(dead: [ { "key" => "zimmer#1", "reason" => "not worth doing" } ])
    end

    assert_match(/human's call/, error.message)
    assert WorkBacklogItem.find_by(key: "zimmer#1").queued?
  end

  test "bounds and shape are enforced" do
    assert_raises(WorkBacklog::Pull::InvalidPull) { WorkBacklog::Pull.call }
    assert_raises(WorkBacklog::Pull::InvalidPull) { WorkBacklog::Pull.call(count: WorkBacklog::Pull::MAX + 1) }
    assert_raises(WorkBacklog::Pull::InvalidPull) { WorkBacklog::Pull.call(count: 1, keys: [ "zimmer#1" ]) }
    assert_raises(WorkBacklog::Pull::InvalidPull) { WorkBacklog::Pull.call(keys: [ "zimmer#1", "zimmer#1" ]) }
    assert_raises(WorkBacklog::Pull::InvalidPull) { WorkBacklog::Pull.call(count: "three") }
    assert_raises(WorkBacklog::Pull::InvalidPull) do
      WorkBacklog::Pull.call(keys: [ "zimmer#1" ], dead: [ { "key" => "zimmer#1", "reason" => "issue_closed" } ])
    end
  end

  test "a pull of zero is a normal outcome that re-ranks and spawns nothing" do
    drifted = backlog_item(cost: "medium", precedence: 6500)

    result = assert_no_difference("Session.count") { WorkBacklog::Pull.call(count: 0) }

    assert_empty result.started
    assert_equal 3000, drifted.reload.precedence
  end

  test "pinned items are pulled like any other" do
    pinned = backlog_item(key: "zimmer#1", precedence: 9000, pinned: true)
    backlog_item(key: "zimmer#2", precedence: 6000)

    result = WorkBacklog::Pull.call(count: 1)

    assert_equal pinned.id, result.started.sole.item.id
  end

  test "a pull with no acting session still works: parentless, genesis api, default precedence" do
    backlog_item(key: "zimmer#1")

    result = WorkBacklog::Pull.call(count: 1)

    session = result.started.sole.session
    assert_nil session.parent_session_id
    assert_equal SessionGenesis::API, session.genesis
    assert_equal "spot", session.scheduling_class
    assert_nil result.started.sole.item.started_by_session_id
  end

  test "a spawn failure leaves every item queued" do
    backlog_item(key: "zimmer#1")
    backlog_item(key: "zimmer#2")

    Session.stub(:create_from_agent_root!, ->(**) { raise ActiveRecord::RecordInvalid }) do
      assert_raises(ActiveRecord::RecordInvalid) { WorkBacklog::Pull.call(count: 2) }
    end

    assert_equal 2, WorkBacklogItem.queued.count
  end

  # --- Start on its own: the "start now as priority" half ------------------

  test "Start at priority spawns a priority session and marks the item started" do
    item = backlog_item(key: "zimmer#1")

    result = WorkBacklog::Start.call(item: item, scheduling_class: SessionGenesis::PRIORITY, genesis: SessionGenesis::API)

    assert_equal "priority", result.session.scheduling_class
    assert_equal SessionGenesis::API, result.session.genesis
    assert_nil result.session.parent_session_id
    assert result.item.started?
    assert_equal result.session.id, result.item.started_session_id
  end

  test "Start refuses an item that is not queued, and spawns nothing" do
    item = backlog_item(key: "zimmer#1")
    item.remove!(reason: "dup", by: "human")

    assert_no_difference("Session.count") do
      assert_raises(WorkBacklog::Start::NotQueued) do
        WorkBacklog::Start.call(item: item, scheduling_class: SessionGenesis::PRIORITY)
      end
    end
  end

  test "Start refuses an unknown scheduling class" do
    item = backlog_item
    assert_raises(ArgumentError) { WorkBacklog::Start.call(item: item, scheduling_class: "urgent") }
  end

  test "an issueless item is started from its verbatim prompt" do
    item = backlog_item(key: "manual-x", issue_url: nil, added_by: "human", payload: { "prompt" => "The verbatim ask." })

    result = WorkBacklog::Start.call(item: item, scheduling_class: SessionGenesis::SPOT)

    assert_equal "The verbatim ask.", result.session.prompt
    assert_nil result.session.custom_metadata["work_backlog_issue"]
  end
end
