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

  # THE THROTTLE, PINNED. `in_flight` is what the groomer subtracts from the WIP
  # ceiling, so every status that is counted here is one that can hold the ceiling
  # shut. A session parked in `needs_input` holding an open PR can sit there for
  # days, which is why it must not be one of them.
  test "in_flight is the started items an agent is still advancing" do
    on_a_worker = backlog_item
    on_a_worker.mark_started!(session: sessions(:running), by: nil)
    asleep = backlog_item
    asleep.mark_started!(session: sessions(:waiting), by: nil)
    parked = backlog_item
    parked.mark_started!(session: sessions(:needs_input), by: nil)
    archived = backlog_item
    archived.mark_started!(session: sessions(:archived), by: nil)
    failed = backlog_item
    failed.mark_started!(session: sessions(:failed), by: nil)
    backlog_item # still queued

    assert_equal [ on_a_worker.id, asleep.id ].sort, WorkBacklogItem.in_flight.pluck(:id).sort
  end

  # THE COUNT THAT MAKES A ZERO PULL READABLE. `spot_held` is a SUBSET of
  # `in_flight`, not a slice taken out of it: a held item is assigned work that
  # will run on its own re-check, so it keeps its WIP slot. What it buys is the
  # ability to tell "the ceiling is full of work being done" from "the ceiling is
  # full of work the gate has never started" — the same number, opposite meanings,
  # and the second one is a fleet idle behind a quota window (#1103).
  test "spot_held is the in_flight items whose sessions the spot gate is holding" do
    held = backlog_item
    held.mark_started!(session: spot_held_session(sessions(:waiting)), by: nil)
    on_a_worker = backlog_item
    on_a_worker.mark_started!(session: sessions(:running), by: nil)

    assert_equal [ held.id ], WorkBacklogItem.spot_held.pluck(:id)
    assert_equal [ held.id, on_a_worker.id ].sort, WorkBacklogItem.in_flight.pluck(:id).sort,
                 "a held item still holds its WIP slot — it is waiting on quota, not on a person"
  end

  test "spot_held is empty when nothing is held, and never counts a parked or ended session" do
    backlog_item.mark_started!(session: sessions(:waiting), by: nil)
    backlog_item.mark_started!(session: sessions(:running), by: nil)
    backlog_item.mark_started!(session: sessions(:needs_input), by: nil)
    backlog_item.mark_started!(session: sessions(:archived), by: nil)

    assert_empty WorkBacklogItem.spot_held,
                 "a session merely queued for a worker is not held at the gate"
  end

  # The marker alone is not the predicate: SpotSessionHold.held? also requires the
  # session to still be `waiting`. A held session that got through and is running
  # keeps its hold record until `clear` drops it, and counting that as held would
  # report a working fleet as a stalled one.
  test "a session that carried a hold record and is now running is not spot_held" do
    item = backlog_item
    got_through = sessions(:running)
    got_through.update!(metadata: (got_through.metadata || {}).merge(
      SpotSessionHold::HELD_REASON => SpotGateService::UTILIZATION_REASON
    ))
    item.mark_started!(session: got_through, by: nil)

    assert_empty WorkBacklogItem.spot_held
    assert_equal [ item.id ], WorkBacklogItem.in_flight.pluck(:id)
  end

  # Deliberately deferred to SpotSessionHold.held_sessions rather than respelled,
  # so this count and the one `get_spot_policy` reports cannot drift. A session
  # also carrying a ceiling pause belongs to that population and its own resume
  # owner, so it is not counted here.
  test "a held session that is also ceiling-paused belongs to the paused population" do
    item = backlog_item
    both = sessions(:waiting)
    both.update!(metadata: (both.metadata || {}).merge(
      SpotSessionHold::HELD_REASON => SpotGateService::UTILIZATION_REASON,
      SpotSessionPause::PAUSED_REASON => SpotGateService::UTILIZATION_REASON
    ))
    item.mark_started!(session: both, by: nil)

    assert_empty WorkBacklogItem.spot_held
  end

  test "an item whose session is parked in needs_input holding an open PR is not in flight" do
    item = backlog_item
    holding_a_pr = sessions(:needs_input)
    holding_a_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/tadasant/zimmer/pull/1" ] })
    item.mark_started!(session: holding_a_pr, by: nil)

    assert_empty WorkBacklogItem.in_flight, "a PR waiting on a human is not work an agent is doing"
    assert_equal [ item.id ], WorkBacklogItem.parked.pluck(:id)
    assert_equal [ item.id ], WorkBacklogItem.claimed.pluck(:id), "but the issue is still claimed"
  end

  test "an item whose session has archived is neither in flight nor parked nor claimed" do
    item = backlog_item
    item.mark_started!(session: sessions(:archived), by: nil, now: 2.hours.ago)
    sessions(:archived).update!(archived_at: 1.hour.ago)

    assert_empty WorkBacklogItem.in_flight
    assert_empty WorkBacklogItem.parked
    assert_empty WorkBacklogItem.claimed
    assert_equal [ item.id ], WorkBacklogItem.ended_since(24.hours.ago).pluck(:id)
  end

  # THE WINDOW IS DATED FROM THE END, NOT THE START, and this is the case that
  # tells the two apart. An item started three days ago whose session archived a
  # minute ago is the SHAPE THIS QUEUE PRODUCES — a session parks on a PR for two
  # days and then a human merges it — so a window measured from `started_at`
  # would drop it at the exact moment it finished.
  test "ended_since dates the window from when the session ended, not when the item started" do
    long_running = backlog_item
    long_running.mark_started!(session: sessions(:archived), by: nil, now: 3.days.ago)
    sessions(:archived).update!(archived_at: 1.minute.ago)

    assert_equal [ long_running.id ], WorkBacklogItem.ended_since(24.hours.ago).pluck(:id),
                 "an item started three days ago whose session just archived has just finished"
  end

  test "ended_since reaches back only as far as it is asked to" do
    recent = backlog_item
    recent.mark_started!(session: sessions(:archived), by: nil, now: 2.hours.ago)
    sessions(:archived).update!(archived_at: 2.hours.ago)
    old = backlog_item
    old.mark_started!(session: sessions(:failed), by: nil, now: 3.days.ago)
    # `failed` carries no end timestamp of its own, so `updated_at` is the proxy.
    sessions(:failed).update_columns(updated_at: 3.days.ago)

    assert_equal [ recent.id ], WorkBacklogItem.ended_since(24.hours.ago).pluck(:id)
    assert_equal [ recent.id, old.id ].sort, WorkBacklogItem.ended_since(1.week.ago).pluck(:id).sort
  end

  test "ended_since ignores a session that has not ended, however old the item is" do
    running = backlog_item
    running.mark_started!(session: sessions(:running), by: nil, now: 3.days.ago)
    parked = backlog_item
    parked.mark_started!(session: sessions(:needs_input), by: nil, now: 3.days.ago)

    assert_empty WorkBacklogItem.ended_since(1.week.ago)
  end

  test "claimed is in_flight plus parked, and never a queued or removed item" do
    live = backlog_item
    live.mark_started!(session: sessions(:running), by: nil)
    parked = backlog_item
    parked.mark_started!(session: sessions(:needs_input), by: nil)
    backlog_item # still queued
    gone = backlog_item
    gone.remove!(reason: "not worth it", by: "human")

    assert_equal (WorkBacklogItem.in_flight.pluck(:id) + WorkBacklogItem.parked.pluck(:id)).sort,
                 WorkBacklogItem.claimed.pluck(:id).sort
    assert_equal [ live.id, parked.id ].sort, WorkBacklogItem.claimed.pluck(:id).sort
    assert_not_includes WorkBacklogItem.claimed.pluck(:id), gone.id
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

  private

  # A session dormant at the spot gate, in the shape SpotSessionHold.hold! leaves:
  # `waiting`, with the hold reason on its metadata.
  def spot_held_session(session)
    session.update!(metadata: (session.metadata || {}).merge(
      SpotSessionHold::HELD_REASON => SpotGateService::UTILIZATION_REASON,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    ))
    session
  end
end
