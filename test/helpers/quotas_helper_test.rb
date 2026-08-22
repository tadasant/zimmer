# frozen_string_literal: true

require "test_helper"

class QuotasHelperTest < ActionView::TestCase
  include QuotasHelper

  # effective_utilization tests

  test "effective_utilization returns original value when reset_time is nil" do
    assert_in_delta 0.85, effective_utilization(0.85, nil)
  end

  test "effective_utilization returns original value when reset_time is in the future" do
    assert_in_delta 0.85, effective_utilization(0.85, 2.hours.from_now)
  end

  test "effective_utilization returns 0.0 when reset_time has passed" do
    assert_in_delta 0.0, effective_utilization(0.95, 1.hour.ago)
  end

  test "effective_utilization returns 0.0 when reset_time is exactly now" do
    assert_in_delta 0.0, effective_utilization(0.95, Time.current)
  end

  test "effective_utilization returns nil when utilization is nil regardless of reset_time" do
    assert_nil effective_utilization(nil, 1.hour.ago)
  end

  # seven_day_window_spent? tests

  test "seven_day_window_spent? is true when the 7-day status is rejecting" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now))
  end

  test "seven_day_window_spent? is true when the 7-day counter reached the cap" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "allowed", reset_7d: 1.day.from_now))
  end

  test "seven_day_window_spent? is false for a healthy 7-day window" do
    assert_not seven_day_window_spent?(snapshot(utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now))
  end

  test "seven_day_window_spent? is false once the rejecting window has reset" do
    assert_not seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.minute.ago))
  end

  test "seven_day_window_spent? is false when there is no 7-day data" do
    assert_not seven_day_window_spent?(snapshot(utilization_7d: nil, status_7d: nil, reset_7d: nil))
  end

  test "seven_day_window_spent? is false for a nil snapshot" do
    assert_not seven_day_window_spent?(nil)
  end

  test "seven_day_window_spent? is false for allowed_warning, which still serves" do
    # Anthropic's third status value. Reading it as blocking would invent
    # exhaustion for an account that is merely approaching its cap.
    assert_not seven_day_window_spent?(snapshot(utilization_7d: 0.82, status_7d: "allowed_warning", reset_7d: 2.days.from_now))
  end

  test "seven_day_window_spent? treats an unrecognized status as blocking" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 0.9, status_7d: "exceeded", reset_7d: 2.days.from_now))
  end

  test "seven_day_window_spent? is true for a rejecting window with no reset time" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "rejected", reset_7d: nil))
  end

  # pool_utilization_5h tests
  #
  # The motivating case: an account reporting plenty of 5-hour headroom while
  # its 7-day window turns every request away. The headroom is fictional, so
  # the pool must see the account as fully utilized.

  test "pool_utilization_5h counts a 7d-rejected account as fully utilized despite a low 5h counter" do
    snap = snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    )

    assert_in_delta 1.0, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h returns the raw 5h value when both windows are healthy" do
    snap = snapshot(
      utilization_5h: 0.45, status_5h: "allowed", reset_5h: 3.hours.from_now,
      utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now
    )

    assert_in_delta 0.45, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h leaves a merely high 7d window alone" do
    snap = snapshot(
      utilization_5h: 0.10, status_5h: "allowed", reset_5h: 3.hours.from_now,
      utilization_7d: 0.95, status_7d: "allowed", reset_7d: 5.days.from_now
    )

    assert_in_delta 0.10, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h leaves an allowed_warning 7d window alone" do
    snap = snapshot(
      utilization_5h: 0.15, status_5h: "allowed", reset_5h: 3.hours.from_now,
      utilization_7d: 0.82, status_7d: "allowed_warning", reset_7d: 2.days.from_now
    )

    assert_in_delta 0.15, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h drops back to the 5h value once the 7d window resets" do
    snap = snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 1.hour.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.minute.ago
    )

    assert_in_delta 0.29, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h honors a reset 5h window when the 7d window is healthy" do
    snap = snapshot(
      utilization_5h: 0.95, status_5h: "allowed", reset_5h: 1.minute.ago,
      utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now
    )

    assert_in_delta 0.0, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h reports a 7d-blocked account with no 5h data as fully utilized" do
    snap = snapshot(
      utilization_5h: nil, status_5h: nil, reset_5h: nil,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    )

    assert_in_delta 1.0, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h returns nil without a snapshot" do
    assert_nil pool_utilization_5h(nil)
  end

  # five_hour_headroom_unusable? tests

  test "five_hour_headroom_unusable? is true when a 7d-spent account still shows 5h headroom" do
    assert five_hour_headroom_unusable?(snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    ))
  end

  test "five_hour_headroom_unusable? is false when the 5h window is spent too" do
    assert_not five_hour_headroom_unusable?(snapshot(
      utilization_5h: 1.0, status_5h: "rejected", reset_5h: 1.hour.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    ))
  end

  test "five_hour_headroom_unusable? is false for a nil snapshot" do
    assert_not five_hour_headroom_unusable?(nil)
  end

  test "five_hour_headroom_unusable? is false when the 7d window is healthy" do
    assert_not five_hour_headroom_unusable?(snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
      utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now
    ))
  end

  # time_until_reset tests

  test "time_until_reset returns N/A for nil" do
    assert_equal "N/A", time_until_reset(nil)
  end

  test "time_until_reset returns Window reset when time has passed" do
    assert_equal "Window reset", time_until_reset(1.hour.ago)
  end

  test "time_until_reset returns formatted time for future reset" do
    result = time_until_reset(3.hours.from_now)
    assert_match(/2h/, result)
    assert_match(/m/, result)
  end

  # The reported bug: minutes are the finest unit, so the last minute before a
  # reset had no whole unit to report and joined to "". The card interpolates
  # this after a label, so the page rendered "Resets in" and nothing else.
  # Frozen, because the boundary is the assertion. `1.minute.from_now` is read
  # before the helper reads Time.current, so under a running clock the gap is a
  # few microseconds under a minute and lands on the branch below it — the
  # 60-second boundary is not reachable at all without holding time still.
  test "time_until_reset names the sub-minute window instead of returning blank" do
    freeze_time { assert_equal "< 1m", time_until_reset(30.seconds.from_now) }
  end

  test "time_until_reset names the sub-minute window one second before reset" do
    freeze_time { assert_equal "< 1m", time_until_reset(1.second.from_now) }
  end

  test "time_until_reset names the sub-minute window at the last instant before reset" do
    freeze_time { assert_equal "< 1m", time_until_reset(Time.current + 0.001) }
  end

  test "time_until_reset switches to whole minutes at exactly one minute" do
    freeze_time { assert_equal "1m", time_until_reset(1.minute.from_now) }
  end

  test "time_until_reset reports a window reset at exactly the reset instant" do
    freeze_time { assert_equal "Window reset", time_until_reset(Time.current) }
  end

  # The guarantee the view depends on: no reset time, at any distance, may
  # render as blank or whitespace after the "Resets in" label. Walks the whole
  # range rather than the boundaries alone, because the empty join came from a
  # combination of components rather than from one special-cased input.
  test "time_until_reset never renders blank for any offset" do
    offsets = [ 0.5, 1, 30, 59, 59.9, 60, 61, 90, 3599, 3600, 3601, 86_399, 86_400,
               86_430, 90_000, 7.days.to_i, 30.days.to_i ]

    freeze_time do
      offsets.each do |seconds|
        result = time_until_reset(Time.current + seconds)
        assert_predicate result.strip, :present?, "time_until_reset rendered blank for +#{seconds}s"
      end
    end
  end

  # window_status_badge tests
  #
  # A status describes the window that was open when the reading was taken.
  # After that window's reset time the card corrects the counter to 0.0% and
  # prints "Window reset" — a red "Rejected" badge left beside them contradicts
  # both, and outlives the window it described.

  test "window_status_badge renders the status while the window is still open" do
    assert_match(/Rejected/, window_status_badge("rejected", 1.day.from_now))
  end

  test "window_status_badge renders the status when there is no reset time" do
    assert_match(/Allowed/, window_status_badge("allowed", nil))
  end

  test "window_status_badge drops a status whose window has already reset" do
    assert_nil window_status_badge("rejected", 1.hour.ago)
  end

  test "window_status_badge drops a serving status whose window has already reset too" do
    # The rule is about the window, not about the colour of the badge: "allowed"
    # read off a window that has since cleared is no more a fact than "rejected".
    assert_nil window_status_badge("allowed", 1.hour.ago)
  end

  test "window_status_badge drops a status whose window resets exactly now" do
    freeze_time { assert_nil window_status_badge("rejected", Time.current) }
  end

  # reset_window_line tests

  test "reset_window_line renders nothing without a reset time" do
    assert_nil reset_window_line(nil)
  end

  test "reset_window_line reports a window that has already reset" do
    line = reset_window_line(1.hour.ago)
    assert_match(/Window reset/, line)
    assert_match(/text-green-500/, line)
  end

  test "reset_window_line reports the wait to a window still open" do
    freeze_time do
      line = reset_window_line(2.hours.from_now + 30.minutes)
      assert_match(/Resets in 2h 30m/, line)
      assert_match(/text-gray-400/, line)
    end
  end

  test "reset_window_line carries a value in the last minute before a reset" do
    freeze_time { assert_match(/Resets in &lt; 1m/, reset_window_line(30.seconds.from_now)) }
  end

  # utilization_percentage_text tests

  test "utilization_percentage_text shows 0.0% for zero" do
    assert_equal "0.0%", utilization_percentage_text(0.0)
  end

  test "utilization_percentage_text shows N/A for nil" do
    assert_equal "N/A", utilization_percentage_text(nil)
  end

  # genesis_kind_state tests — the spot gate renders each kind twice (a card below
  # `sm`, a table row above it), and both readings come from here so they cannot
  # disagree about the class a kind carries or the class a click would move it to.

  test "genesis_kind_state offers spot as the target for a priority kind" do
    kind = SessionGenesis.kind(SessionGenesis::WEB_UI)
    current, target, overridden, badge = genesis_kind_state(kind, { kind.key => SessionGenesis::PRIORITY })

    assert_equal SessionGenesis::PRIORITY, current
    assert_equal SessionGenesis::SPOT, target
    assert_not overridden, "a kind sitting on its default is not overridden"
    assert_equal "bg-indigo-100 text-indigo-800", badge
  end

  test "genesis_kind_state flags a kind moved off its default and offers the way back" do
    kind = SessionGenesis.kind(SessionGenesis::WEB_UI)
    current, target, overridden, badge = genesis_kind_state(kind, { kind.key => SessionGenesis::SPOT })

    assert_equal SessionGenesis::SPOT, current
    assert_equal SessionGenesis::PRIORITY, target
    assert overridden
    assert_equal "bg-gray-100 text-gray-700", badge
  end

  # account_status_badge — the account-level badge, derived the way the
  # per-window badge already is.

  test "account_status_badge drops the exceeded label once the windows have cleared" do
    account = claude_accounts(:exceeded)
    cleared = snapshot(utilization_5h: 0.35, status_5h: "allowed", reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, status_7d: "allowed", reset_7d: 6.days.from_now)

    badge = account_status_badge(account, cleared)

    assert_match "Active", badge
    assert_no_match(/Quota Exceeded/, badge)
  end

  test "account_status_badge keeps the exceeded label while the week is genuinely spent" do
    account = claude_accounts(:exceeded)
    rejecting = snapshot(utilization_5h: 0.0, status_5h: "allowed", reset_5h: 2.hours.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 3.days.from_now)

    assert_match "Quota Exceeded", account_status_badge(account, rejecting)
  end

  test "account_status_badge keeps the exceeded label when there is no reading" do
    assert_match "Quota Exceeded", account_status_badge(claude_accounts(:exceeded), nil)
  end

  test "account_status_badge renders the plain statuses unchanged" do
    assert_match "Active", account_status_badge(claude_accounts(:primary), nil)
    assert_match "Needs Reauth", account_status_badge_tag("needs_reauth")
  end

  # The Account Pool's "we're blocked until X" notes.

  test "pool_capacity_banner counts down to the moment the pool has capacity" do
    banner = pool_capacity_banner(measure(next_capacity_at: 90.minutes.from_now, blocked_count: 2))

    assert_match "Work unblocked in", banner
    assert_match(/1:29:5\d|1:30:00/, banner)
    assert_match "room on both its 5-hour and 7-day windows", banner
    assert_match "All 2 accounts with a reading are out of capacity.", banner
    assert_match "UTC", banner
    assert_match(/data-controller="local-time"/, banner)
  end

  # The tick is driven off the absolute instant in the markup, not off the
  # duration rendered beside it — a page left open would otherwise keep showing
  # the wait as it stood when the server drew it.
  test "pool_capacity_banner hands the browser an absolute deadline to tick from" do
    at = 2.hours.from_now.change(usec: 0)

    banner = pool_capacity_banner(measure(next_capacity_at: at, read_count: 1, blocked_count: 1))

    assert_match(/data-controller="unblock-countdown"/, banner)
    assert_match "data-unblock-countdown-deadline-value=\"#{at.utc.iso8601}\"", banner
    assert_match 'data-unblock-countdown-target="remaining"', banner
    assert_match 'data-unblock-countdown-target="label"', banner
    assert_match 'data-unblock-countdown-target="passed"', banner
  end

  # There is nothing to count down to when the pool is already serving, and a
  # clock ticking toward the next rollover would read as a wait that isn't one.
  test "pool_capacity_banner says the pool is not blocked when an account has room" do
    banner = pool_capacity_banner(measure(read_count: 3, blocked_count: 1))

    assert_match "Work is not blocked", banner
    assert_match "2 accounts of 3 with a reading have room on both windows", banner
    assert_no_match(/unblock-countdown/, banner)
  end

  test "pool_capacity_banner reads singly when one account is serving" do
    banner = pool_capacity_banner(measure(read_count: 2, blocked_count: 1))

    assert_match "1 account of 2 with a reading has room on both windows", banner
  end

  # Blocked with no recorded reset anywhere: a zeroed clock would read as "any
  # moment now", so the banner says the page cannot tell.
  test "pool_capacity_banner owns up to a blocked pool with no recorded reset" do
    banner = pool_capacity_banner(
      measure(next_capacity_at: nil, read_count: 3, blocked_count: 3, weekly_spent_count: 3)
    )

    assert_match "Nothing here says when work resumes", banner
    assert_match "All 3 accounts with a reading are out of capacity.", banner
    assert_no_match(/unblock-countdown/, banner)
  end

  # Nothing read means nothing is known, which is not the same as everything
  # being spent — any banner here would be a claim on no evidence.
  test "pool_capacity_banner renders nothing for a pool with no readings" do
    assert_nil pool_capacity_banner(measure(read_count: 0, blocked_count: 0))
  end

  # The measure is taken before the view renders, so the deadline can cross now
  # in between. The clock says "now" rather than a negative wait, and the
  # controller reveals the note beside it the moment it connects.
  test "pool_capacity_banner does not render a negative wait" do
    banner = pool_capacity_banner(measure(next_capacity_at: 1.second.ago, read_count: 1, blocked_count: 1))

    assert_match "The one account with a reading is out of capacity.", banner
    assert_match ">now<", banner
    assert_match ">Work unblocked<", banner
    # The note is in the markup either way; whether it is hidden is the state.
    assert_no_match(/hidden="hidden"/, banner)
  end

  # The counterpart: with the deadline still ahead, the same note ships hidden
  # and the controller reveals it if the moment passes while the page is open.
  test "pool_capacity_banner keeps the passed note out of the way while the wait is real" do
    banner = pool_capacity_banner(measure(next_capacity_at: 20.minutes.from_now, blocked_count: 2))

    assert_match ">Work unblocked in<", banner
    # The passed note is the only element in the banner that can carry it.
    assert_match 'hidden="hidden"', banner
  end

  test "countdown_clock_text ticks in seconds, and grows a unit as the wait does" do
    freeze_time do
      assert_equal "0:45", countdown_clock_text(45.seconds.from_now)
      assert_equal "9:05", countdown_clock_text(545.seconds.from_now)
      assert_equal "1:30:00", countdown_clock_text(90.minutes.from_now)
      assert_equal "2d 03:04:05", countdown_clock_text((2.days + 3.hours + 4.minutes + 5.seconds).from_now)
      assert_equal "now", countdown_clock_text(1.second.ago)
    end
  end

  test "pool_weekly_reset_line names the reset, the wait, and how many accounts are waiting on it" do
    line = pool_weekly_reset_line(measure(next_weekly_reset: 2.days.from_now, read_count: 4, weekly_spent_count: 3))

    assert_match "Next 7-day reset", line
    assert_match(/in 1d 23h|in 2d/, line)
    assert_match "the soonest recorded among 3 accounts whose 7-day window is spent", line
  end

  test "pool_weekly_reset_line says nothing is waiting when no week is spent" do
    line = pool_weekly_reset_line(measure(next_weekly_reset: nil, read_count: 2, weekly_spent_count: 0))

    assert_match "No account&#39;s 7-day window is spent", line
  end

  test "pool_weekly_reset_line owns up to a spent week with no recorded reset time" do
    line = pool_weekly_reset_line(measure(next_weekly_reset: nil, read_count: 1, weekly_spent_count: 1))

    assert_match "1 account with a spent 7-day window", line
    assert_match "no reset time recorded for it", line
  end

  test "pool_reset_time carries the UTC reading in the text, the datetime, and the title" do
    at = Time.utc(2026, 8, 20, 6, 58)

    tag = pool_reset_time(at)

    assert_match "Aug 20, 06:58 UTC", tag
    assert_match 'datetime="2026-08-20T06:58:00Z"', tag
    assert_match 'title="Aug 20, 06:58 UTC"', tag
  end

  private

  # A pool measure with only the fields these notes read set to anything
  # interesting.
  def measure(**overrides)
    ClaudeAccountPool::Measure.new(**{
      five_hour: 0.5, weekly: 0.5, worst_five_hour: 0.5, worst_weekly: 0.5,
      account_count: 2, read_count: 2, weekly_spent_count: 0, blocked_count: 2,
      next_capacity_at: nil, next_weekly_reset: nil
    }.merge(overrides))
  end

  def snapshot(**attributes)
    ClaudeAccountQuotaSnapshot.new(**attributes)
  end
end
