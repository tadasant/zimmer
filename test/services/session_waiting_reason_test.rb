# frozen_string_literal: true

require "test_helper"

# A `waiting` session can carry all three park records at once, and until #642
# every surface that answered "why is this waiting" read whichever it checked
# first. These tests pin the ranking that replaced that.
class SessionWaitingReasonTest < ActiveSupport::TestCase
  def waiting_session(metadata)
    sessions(:running).tap do |session|
      session.update!(status: :waiting, scheduling_class: SessionGenesis::SPOT, metadata: metadata)
    end
  end

  def hold(at:, retry_at:, reason: "at_utilization_limit")
    {
      SpotSessionHold::HELD_AT => at,
      SpotSessionHold::HELD_RETRY_AT => retry_at,
      SpotSessionHold::HELD_REASON => reason,
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_COUNT => 25,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    }
  end

  def pause(at:, reason: "at_utilization_limit")
    {
      SpotSessionPause::PAUSED_AT => at,
      SpotSessionPause::PAUSED_REASON => reason,
      SpotSessionPause::PAUSED_DETAIL => "Pausing spot sessions: the 5-hour window's spot budget is spent.",
      SpotSessionPause::PAUSED_COUNT => 2
    }
  end

  def park(at:, reason: AuthOutageParkService::QUOTA_EXHAUSTED)
    { "auth_outage_reason" => reason, "auth_outage_parked_at" => at }
  end

  test "a session dormant on none of the three has no waiting reason" do
    assert_nil SessionWaitingReason.for(sessions(:running))
    assert_nil SessionWaitingReason.for(nil)
  end

  # Session 6808, as reported: a start-hold whose own re-check was two days in the
  # past, beside an auth-outage park a full day newer.
  test "an outage park outranks an expired start-hold recorded a day earlier" do
    session = waiting_session(
      hold(at: "2026-08-21T11:16:53Z", retry_at: "2026-08-21T12:18:21Z")
        .merge(park(at: "2026-08-22T11:50:51Z"))
    )

    reading = SessionWaitingReason.for(session)

    assert_equal SessionWaitingReason::AUTH_OUTAGE_PARK, reading.current.key
    assert_equal [ SessionWaitingReason::SPOT_HOLD ], reading.superseded.map(&:key)
    assert reading.superseded.first.demoted?, "an overdue hold beside a park has no sweep coming for it"
  end

  # Session 7503, as reported: fifteen seconds is still newer, and the two have
  # different resume owners.
  test "an outage park outranks a ceiling pause recorded fifteen seconds earlier" do
    session = waiting_session(
      pause(at: "2026-08-22T16:59:15Z").merge(park(at: "2026-08-22T16:59:30Z"))
    )

    reading = SessionWaitingReason.for(session)

    assert_equal SessionWaitingReason::AUTH_OUTAGE_PARK, reading.current.key
    assert_equal [ SessionWaitingReason::SPOT_PAUSE ], reading.superseded.map(&:key)
    refute reading.superseded.first.demoted?, "a pause is superseded by age, not by a stalled ladder"
  end

  # The rule is recency, not a fixed pecking order: a park that has been sitting
  # there for a day does not outrank the hold that was taken since.
  test "a live hold taken after the park is the current reason" do
    session = waiting_session(
      park(at: "2026-08-22T11:50:51Z")
        .merge(hold(at: "2026-08-22T14:00:00Z", retry_at: 20.minutes.from_now.utc.iso8601))
    )

    reading = SessionWaitingReason.for(session)

    assert_equal SessionWaitingReason::SPOT_HOLD, reading.current.key
    assert_equal [ SessionWaitingReason::AUTH_OUTAGE_PARK ], reading.superseded.map(&:key)
  end

  # SpotSessionHold.held_sessions excludes a session that also carries a park, and
  # #rearm! refuses one — so the sweep will never repair this ladder, and naming it
  # as the reason would point at an owner that has already declined the session.
  test "an overdue hold loses the headline even when it is the newest record" do
    session = waiting_session(
      park(at: "2026-08-22T11:50:51Z")
        .merge(hold(at: "2026-08-22T14:00:00Z", retry_at: 3.hours.ago.utc.iso8601))
    )

    reading = SessionWaitingReason.for(session)

    assert_equal SessionWaitingReason::AUTH_OUTAGE_PARK, reading.current.key
    assert reading.superseded.first.demoted?
  end

  # ...but only because something else could carry it. On its own the sweep IS its
  # owner, and #723 made that promise true, so the hold keeps the headline.
  test "an overdue hold on its own is still the reason, because the sweep repairs it" do
    session = waiting_session(hold(at: 11.hours.ago.utc.iso8601, retry_at: 10.hours.ago.utc.iso8601))

    reading = SessionWaitingReason.for(session)

    assert_equal SessionWaitingReason::SPOT_HOLD, reading.current.key
    refute reading.current.demoted?
    assert_empty reading.superseded
  end

  # An unparseable or absent stamp must not win by accident: "no timestamp" is not
  # "the beginning of time", and the mechanism that can prove when it fired wins.
  test "a mechanism with no usable timestamp ranks below one that has one" do
    session = waiting_session(
      hold(at: nil, retry_at: nil).merge(park(at: "2026-08-22T11:50:51Z"))
    )
    assert_equal SessionWaitingReason::AUTH_OUTAGE_PARK, SessionWaitingReason.for(session).current.key

    session.update!(metadata: hold(at: "not a timestamp", retry_at: nil)
      .merge(park(at: "2026-08-22T11:50:51Z")))
    assert_equal SessionWaitingReason::AUTH_OUTAGE_PARK, SessionWaitingReason.for(session).current.key
  end

  # All three at once, which is the shape the ranking exists for.
  test "all three mechanisms rank newest first" do
    session = waiting_session(
      hold(at: "2026-08-21T11:16:53Z", retry_at: 20.minutes.from_now.utc.iso8601)
        .merge(pause(at: "2026-08-23T09:00:00Z"))
        .merge(park(at: "2026-08-22T11:50:51Z"))
    )

    assert_equal [ SessionWaitingReason::SPOT_PAUSE,
                   SessionWaitingReason::AUTH_OUTAGE_PARK,
                   SessionWaitingReason::SPOT_HOLD ],
                 SessionWaitingReason.ranked(session).map(&:key)
  end

  # #spot is what the session page's single spot banner picks between, and it has
  # to agree with the ranking rather than defaulting to the hold.
  test "the spot banner's mechanism is the higher-ranked of a hold and a pause" do
    session = waiting_session(
      hold(at: "2026-08-21T11:16:53Z", retry_at: 20.minutes.from_now.utc.iso8601)
        .merge(pause(at: "2026-08-23T09:00:00Z"))
    )

    reading = SessionWaitingReason.for(session)

    assert_equal SessionWaitingReason::SPOT_PAUSE, reading.spot.key
    assert reading.current?(reading.spot)
  end

  # Every mechanism is gated on `waiting?` by its own predicate. A session that has
  # moved on keeps these records deliberately, and reading them back as live state
  # would tell an agent something false about its own session.
  test "a session that is no longer waiting has no waiting reason" do
    session = waiting_session(
      hold(at: "2026-08-21T11:16:53Z", retry_at: "2026-08-21T12:18:21Z")
        .merge(park(at: "2026-08-22T11:50:51Z"))
    )
    assert SessionWaitingReason.for(session)

    session.update_columns(status: Session.statuses[:archived])

    assert_nil SessionWaitingReason.for(session.reload)
  end
end
