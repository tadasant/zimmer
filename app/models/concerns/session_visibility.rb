# frozen_string_literal: true

# Board visibility — the session's SECOND axis, and the one that decides nothing.
#
# `status` says what a session is doing. `visibility` says whether the operator
# wants to look at it right now: `visible`, `hidden`, or `snoozed` until a chosen
# time. That is the whole of it. It is a way of tidying a board, in the same
# family as the `favorited` star and the category a card sits in.
#
# **It is strictly orthogonal to everything else.** Nothing here reads or writes
# `status`, `scheduling_class`, `precedence`, the spot queue, triggers, wake-ups
# or the quota gate, and nothing in those places reads these two columns. A
# snoozed session runs exactly when it would have run had nobody snoozed it — the
# card simply is not on screen. The control that genuinely sleeps a session is
# "Pause Until" (Sessions::ScheduleWakeUp / Sessions::PauseIntoSpotQueue), which
# is a different control, doing a different thing, that happens to sit in the same
# menu. If a change here ever needs to consult the lifecycle, that is a bug in the
# change rather than a gap here.
#
# A snooze ENDS BY BEING READ, not by being swept. `board_visible` treats a
# `snoozed` row whose `snoozed_until` has passed as visible, so a session comes
# back on its own with no job mutating rows behind it — which also means there is
# no background writer that could collide with the lifecycle.
module SessionVisibility
  extend ActiveSupport::Concern

  VISIBLE = "visible"
  HIDDEN = "hidden"
  SNOOZED = "snoozed"
  VISIBILITIES = [ VISIBLE, HIDDEN, SNOOZED ].freeze

  # Choices offered by the "Snooze until…" menu, in order. `key` is the contract
  # with visibility_controller.js, which resolves each one to an absolute time in
  # the BROWSER's timezone — "Tomorrow, 9 AM" means the operator's morning, not
  # the server's, and only the browser knows which that is. Anything not on this
  # list goes through the datetime picker instead.
  #
  # Chosen for the case this feature was built for: "I have more queued than I can
  # touch in the next 48 hours, push the rest a few days out." Hence two short
  # hops, an explicit multi-day one, and the two calendar landmarks.
  #
  # Five rather than six: an "In 2 days" sat between "Tomorrow" and "In 3 days"
  # and resolved to the same instant as "This weekend" every Thursday, which is a
  # menu with two rows that do the same thing. A relative-days preset will
  # occasionally coincide with a calendar one whatever the set — each row shows
  # the time it resolves to, so the overlap is visible rather than surprising —
  # but there is no reason to carry the one that overlaps most.
  SNOOZE_PRESETS = [
    { key: "later_today", label: "Later today" },
    { key: "tomorrow", label: "Tomorrow" },
    { key: "in_3_days", label: "In 3 days" },
    { key: "this_weekend", label: "This weekend" },
    { key: "next_week", label: "Next week" }
  ].freeze

  included do
    validates :visibility, inclusion: { in: VISIBILITIES, message: "%{value} is not a valid visibility" }

    # Sessions the board shows by default: plainly visible, or snoozed to a time
    # that has already passed. The second clause is what makes a snooze expire on
    # read — see the note at the top of this file.
    scope :board_visible, ->(now = Time.current) {
      where(
        "sessions.visibility = :visible OR (sessions.visibility = :snoozed AND sessions.snoozed_until IS NOT NULL AND sessions.snoozed_until <= :now)",
        visible: VISIBLE, snoozed: SNOOZED, now: now
      )
    }

    # The complement: everything tucked away right now — hidden, or snoozed to a
    # time still in the future. A `snoozed` row with a NULL `snoozed_until` cannot
    # be written through Sessions::SetVisibility, but if one ever existed it counts
    # as tucked away here and is excluded by `board_visible` above, so the two
    # scopes stay exact complements of each other.
    scope :board_hidden, ->(now = Time.current) {
      where(
        "sessions.visibility = :hidden OR (sessions.visibility = :snoozed AND (sessions.snoozed_until IS NULL OR sessions.snoozed_until > :now))",
        hidden: HIDDEN, snoozed: SNOOZED, now: now
      )
    }
  end

  # True while a snooze is still running. A `snoozed` row whose time has passed is
  # simply visible again.
  def snooze_active?(now = Time.current)
    visibility == SNOOZED && snoozed_until.present? && snoozed_until > now
  end

  # Whether this session belongs on a board that is not revealing tucked-away
  # sessions. The row-level counterpart of the `board_visible` scope; keep the two
  # answering identically.
  def board_visible?(now = Time.current)
    return true if visibility == VISIBLE
    return false if visibility == HIDDEN

    # SNOOZED. A snooze whose time has passed is over; one with no time at all is
    # not a snooze that can end, so it stays off the board rather than being
    # silently ignored. Written as the positive form of the `board_visible` scope's
    # second clause on purpose — the dashboard filters with the scope and draws
    # badges with this, and the two disagreeing is a card that is on screen while
    # the page believes it is not.
    snoozed_until.present? && snoozed_until <= now
  end

  # What the visibility column MEANS right now, with an expired snooze already
  # resolved to "visible". This is the value every read surface reports — the raw
  # column is reported alongside it where a caller needs to tell "snoozed, expired"
  # from "never snoozed".
  def effective_visibility(now = Time.current)
    board_visible?(now) ? VISIBLE : visibility
  end

  # One line of English for the card badge, the API and the MCP listing. nil when
  # the session is on the board, so callers can render it or not without a
  # second predicate.
  def visibility_summary(now = Time.current)
    return nil if board_visible?(now)
    return "Hidden from the board" if visibility == HIDDEN

    "Snoozed until #{snoozed_until.utc.iso8601}"
  end
end
