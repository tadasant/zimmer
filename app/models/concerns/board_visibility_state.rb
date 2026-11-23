# frozen_string_literal: true

# What a `visibility` + `snoozed_until` pair MEANS right now, for any record that
# carries the two columns: a Session (through SessionVisibility, which adds the
# SQL scopes and the validation) and a BoardCategory (Your board, where a
# whole category is snoozed or backlogged as a unit).
#
# Pure reads over the two attributes. Like the rest of board visibility, nothing
# here touches status, scheduling or the spot queue.
module BoardVisibilityState
  extend ActiveSupport::Concern

  def backlogged?
    visibility == SessionVisibility::BACKLOGGED
  end

  # True while a snooze is still running. A `snoozed` row whose time has passed is
  # simply visible again.
  def snooze_active?(now = Time.current)
    visibility == SessionVisibility::SNOOZED && snoozed_until.present? && snoozed_until > now
  end

  # Whether this session belongs on a board that is not revealing tucked-away
  # sessions. The row-level counterpart of the `board_visible` scope; keep the two
  # answering identically.
  def board_visible?(now = Time.current)
    return true if visibility == SessionVisibility::VISIBLE
    return false if visibility == SessionVisibility::HIDDEN || visibility == SessionVisibility::BACKLOGGED

    # SessionVisibility::SNOOZED. A snooze whose time has passed is over; one with no time at all is
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
    board_visible?(now) ? SessionVisibility::VISIBLE : visibility
  end

  # One line of English for the card badge, the API and the MCP listing. nil when
  # the session is on the board, so callers can render it or not without a
  # second predicate.
  def visibility_summary(now = Time.current)
    return nil if board_visible?(now)
    return "Hidden from the board" if visibility == SessionVisibility::HIDDEN
    return "Backlogged — parked as low priority, with no end time" if visibility == SessionVisibility::BACKLOGGED
    # Only reachable for a row written before snoozed_until became required. It
    # renders rather than raising, because the surfaces that call this are a card
    # badge and two MCP listings — one such row must not take a whole page with it.
    return "Snoozed with no end time" if snoozed_until.blank?

    "Snoozed until #{snoozed_until.utc.iso8601}"
  end
end
