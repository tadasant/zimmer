# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

class WorkBacklogItemTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  test "a well-formed item is valid and reads its payload fields" do
    item = backlog_item(payload: { "ratings" => { "requirement_impact" => "large" }, "notes" => "n",
                                   "gate_session" => "https://zimmer.example.com/sessions/1" })

    assert item.valid?
    assert_equal({ "requirement_impact" => "large" }, item.ratings)
    assert_equal "n", item.notes
    assert_equal "https://zimmer.example.com/sessions/1", item.gate_session_url
    assert_nil item.prompt
    assert item.queued?
    assert item.in_band?
  end

  test "enums are enforced" do
    item = backlog_item
    item.estimated_cost = "huge"
    assert_not item.valid?
    item.estimated_cost = "small"
    item.scope_direction = "sideways"
    assert_not item.valid?
    item.scope_direction = "convergent"
    item.status = "done"
    assert_not item.valid?
    item.status = "queued"
    item.added_via = "carrier-pigeon"
    assert_not item.valid?
  end

  test "repo must be owner/name" do
    item = backlog_item
    item.repo = "zimmer"
    assert_not item.valid?
    assert_match(/owner\/name/, item.errors.full_messages.join)
  end

  test "an issueless item needs a prompt and a human or the migration behind it" do
    item = backlog_item
    item.assign_attributes(issue_url: nil, added_by: "issue-work-gate", payload: {})

    assert_not item.valid?
    assert_match(/prompt/i, item.errors.full_messages.join)
    assert_match(/added by must be one of human, queue-migration/i, item.errors.full_messages.join)

    item.added_by = "human"
    item.payload = { "prompt" => "Do the thing, verbatim." }
    assert item.valid?
    assert item.issueless?
    assert_equal "Do the thing, verbatim.", item.session_prompt
  end

  test "the same key may exist as history but only once as queued" do
    first = backlog_item(key: "zimmer#1")
    first.mark_started!(session: sessions(:running), by: nil)

    assert_nothing_raised { backlog_item(key: "zimmer#1") }
    assert_raises(ActiveRecord::RecordNotUnique) { backlog_item(key: "zimmer#1") }
  end

  test "removal needs a reason" do
    item = backlog_item
    assert_raises(ActiveRecord::RecordInvalid) { item.remove!(reason: "", by: "human") }

    item.remove!(reason: "duplicate of zimmer#2", by: "human")
    assert item.removed?
    assert_equal "human", item.removed_by
    assert item.removed_at.present?
  end

  test "session prompt is the issue URL plus the ask, and a note beside an issue rides along" do
    item = backlog_item(key: "zimmer#42")
    assert_equal "https://github.com/tadasant/zimmer/issues/42\n\nPlease implement this.", item.session_prompt

    item.payload = item.payload.merge("prompt" => "Approach it via the poller.")
    assert_equal "https://github.com/tadasant/zimmer/issues/42\n\nApproach it via the poller.", item.session_prompt
  end

  test "precedence must fit a Postgres integer" do
    item = backlog_item
    item.precedence = 2**31
    assert_not item.valid?
    item.precedence = -(2**31) - 1
    assert_not item.valid?
    item.precedence = 2**31 - 1
    assert item.valid?
  end

  test "session title never exceeds what Session accepts, and keeps its prefix" do
    long = backlog_item(key: "zimmer#12345", title: "T" * 300)
    assert_equal WorkBacklogItem::SESSION_TITLE_MAX, long.session_title.length
    assert long.session_title.start_with?("Implement zimmer#12345 (")
    assert long.session_title.end_with?("…)")

    short = backlog_item(key: "zimmer#1", title: "Short")
    assert_equal "Implement zimmer#1 (Short)", short.session_title
  end

  test "session title is what the groomer wrote" do
    item = backlog_item(key: "zimmer#42", title: "Fix the thing")
    assert_equal "Implement zimmer#42 (Fix the thing)", item.session_title

    manual = backlog_item(key: "manual-refresh", issue_url: nil, added_by: "human", title: "Refresh",
                          payload: { "prompt" => "x" })
    assert_equal "Implement manual-refresh (Refresh)", manual.session_title
  end

  test "in_flight counts started items whose session is still alive" do
    live = backlog_item
    live.mark_started!(session: sessions(:running), by: nil)
    finished = backlog_item
    finished.mark_started!(session: sessions(:archived), by: nil)
    backlog_item # still queued

    assert_equal [ live.id ], WorkBacklogItem.in_flight.pluck(:id)
  end

  test "in_rank_order is precedence desc, then added_at asc, then id" do
    older = backlog_item(precedence: 6000, added_at: 2.days.ago)
    newer = backlog_item(precedence: 6000, added_at: 1.day.ago)
    top = backlog_item(precedence: 6500)

    assert_equal [ top.id, older.id, newer.id ], WorkBacklogItem.in_rank_order.pluck(:id)
  end

  test "payload must be an object and bounded" do
    item = backlog_item
    item.payload = "nope"
    assert_not item.valid?

    item.payload = { "big" => "x" * (WorkBacklogItem::MAX_PAYLOAD_BYTES + 1) }
    assert_not item.valid?
    assert_match(/too large/, item.errors.full_messages.join)
  end

  test "as_api_json carries the promoted columns, the payload readers and the whole payload" do
    item = backlog_item(payload: { "ratings" => { "a" => "b" }, "extra_from_the_gate" => 1 })
    json = item.as_api_json

    assert_equal item.key, json[:key]
    assert_equal({ "a" => "b" }, json[:ratings])
    assert_equal 1, json.dig(:payload, "extra_from_the_gate")
    assert_equal "queued", json[:status]
  end
end
