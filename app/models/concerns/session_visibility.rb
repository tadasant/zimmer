# frozen_string_literal: true

# Board visibility — the session's SECOND axis, and the one that decides nothing.
#
# `status` says what a session is doing. `visibility` says whether the operator
# wants to look at it right now: `visible`, `hidden`, `snoozed` until a chosen
# time, or `backlogged`. That is the whole of it. It is a way of tidying a board.
#
# `backlogged` is "snooze indefinitely, because it is low priority": a session
# with real progress the operator wants parked, not lost. It is kept apart from
# `hidden` so a board can show the backlog on its own — the operator goes looking
# for it when they have room — rather than mixed in with the cards they tucked
# away for some other reason. Like `hidden` it has no end time.
#
# **It is strictly orthogonal to everything else.** Nothing here reads or writes
# `status`, `scheduling_class`, `precedence`, the spot queue, triggers, wake-ups
# or the quota gate, and nothing in those places reads these two columns. A
# snoozed session runs exactly when it would have run had nobody snoozed it — the
# card simply is not on screen. What genuinely sleeps a session is
# Sessions::ScheduleWakeUp / Sessions::PauseIntoSpotQueue, reached only over MCP —
# a different thing entirely, and no web-UI control does it. If a change here ever
# needs to consult the lifecycle, that is a bug in the change rather than a gap
# here.
#
# A snooze ENDS BY BEING READ, not by being swept. `board_visible` treats a
# `snoozed` row whose `snoozed_until` has passed as visible, so a session comes
# back on its own with no job mutating rows behind it — which also means there is
# no background writer that could collide with the lifecycle.
module SessionVisibility
  extend ActiveSupport::Concern
  # The row-level predicates (board_visible?, visibility_summary, ...) live in
  # BoardVisibilityState, shared with BoardCategory so a snoozed category and a
  # snoozed session end the same way: by being read.
  include BoardVisibilityState

  VISIBLE = "visible"
  HIDDEN = "hidden"
  SNOOZED = "snoozed"
  BACKLOGGED = "backlogged"
  VISIBILITIES = [ VISIBLE, HIDDEN, SNOOZED, BACKLOGGED ].freeze

  # How a listing may narrow on this axis: the sessions a tidied board shows, the
  # ones snoozed or hidden from it, the backlog, or everything. The first three
  # are a partition — every session is in exactly one of them — and `all` is
  # their union. They live here rather than on the dashboard
  # controller because every surface filters on them — the dashboard, the REST
  # listings and the MCP search — and an MCP tool should not have to autoload a
  # web controller to name a filter value.
  FILTER_ON_BOARD = "on_board"
  FILTER_OFF_BOARD = "off_board"
  FILTER_BACKLOGGED = "backlogged"
  FILTER_ALL = "all"
  FILTER_OPTIONS = [ FILTER_ON_BOARD, FILTER_OFF_BOARD, FILTER_BACKLOGGED, FILTER_ALL ].freeze

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
    # A snooze with no end time is a snooze that cannot end. Sessions::SetVisibility
    # already refuses to write one, but nothing stopped a direct `update!` from
    # creating a row every read surface would then have to special-case.
    validates :snoozed_until, presence: { message: "is required when a session is snoozed" },
              if: -> { visibility == SNOOZED }

    # Sessions the board shows by default: plainly visible, or snoozed to a time
    # that has already passed. The second clause is what makes a snooze expire on
    # read — see the note at the top of this file.
    scope :board_visible, ->(now = Time.current) {
      where(
        "sessions.visibility = :visible OR (sessions.visibility = :snoozed AND sessions.snoozed_until IS NOT NULL AND sessions.snoozed_until <= :now)",
        visible: VISIBLE, snoozed: SNOOZED, now: now
      )
    }

    # Snoozed & hidden: hidden, or snoozed to a time still in the future. The
    # validation above stops a `snoozed` row with a NULL `snoozed_until` being
    # written, but rows predating it are still counted as tucked away here and
    # excluded by `board_visible` above. Backlogged sessions are in neither — they
    # are `board_backlogged` — so the three scopes partition the table whatever is
    # in it.
    scope :board_hidden, ->(now = Time.current) {
      where(
        "sessions.visibility = :hidden OR (sessions.visibility = :snoozed AND (sessions.snoozed_until IS NULL OR sessions.snoozed_until > :now))",
        hidden: HIDDEN, snoozed: SNOOZED, now: now
      )
    }

    # The backlog: parked as low priority, with no end time.
    scope :board_backlogged, -> { where(visibility: BACKLOGGED) }

    # One of FILTER_OPTIONS applied to a listing. Anything else — nil, blank, an
    # unrecognized value — falls back to the tidied board, or with
    # `unset_means_all: true` to every session: the REST and MCP listings are
    # unfiltered unless asked, so an agent's duplicate check never loses a session
    # to a human tidying their board.
    scope :board_visibility_filter, ->(filter, unset_means_all: false) {
      case filter.to_s
      when FILTER_ON_BOARD then board_visible
      when FILTER_OFF_BOARD then board_hidden
      when FILTER_BACKLOGGED then board_backlogged
      when FILTER_ALL then all
      else unset_means_all ? all : board_visible
      end
    }
  end
end
