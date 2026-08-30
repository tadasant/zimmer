require "test_helper"

# What the Ranked view (`/?view=ranked`) is told over `Session::RANKED_STREAM`.
#
# The stream carries two different things and the difference is the whole design:
#
#   * a status change replaces ONE element, the row's status pill, because the row
#     around it holds a precedence the user may be mid-edit on and a position
#     SortableJS may be dragging;
#   * a membership change ships an ENVELOPE — the session's filterable facts plus
#     its row inside an inert <template> — because one stream serves every open
#     page and only the page knows its own filters.
#
# The bug these pin: the stream used to broadcast a bare `remove` on archive,
# which is right for an operator watching live work and wrong for the one who
# ticked "Archived" to go through the trash. Both are on this channel.
class SessionRankedBroadcastTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  def create_session(**attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "do the thing",
      title: "Ranked broadcast subject",
      **attrs
    )
  end

  # Everything sent to the ranked stream while the block runs, as strings.
  def ranked_broadcasts
    capture_broadcasts(Session::RANKED_STREAM) { yield }.map(&:to_s)
  end

  def deliveries(payloads)
    payloads.select { |html| html.include?("data-ranked-queue-target=\"delivery\"") }
  end

  def pill_replacements(payloads)
    payloads.select { |html| html.include?("target=\"ranked_row_status_") }
  end

  # A ranked payload is a whole rendered row, so asserting on the raw strings
  # prints kilobytes of markup on failure. The turbo-stream action and target are
  # what the assertions below are actually about.
  def stream_targets(payloads)
    payloads.map { |html| html[/\A<turbo-stream [^>]*>/].to_s.strip }
  end

  test "a new session is offered to every open queue as a delivery envelope" do
    session = nil
    payloads = ranked_broadcasts { session = create_session(scheduling_class: SessionGenesis::SPOT, precedence: 700) }

    envelope = deliveries(payloads).sole
    assert_includes envelope, "target=\"ranked_deliveries\""
    assert_includes envelope, "action=\"append\""
    assert_includes envelope, "data-session-id=\"#{session.id}\""
    assert_includes envelope, "data-status=\"waiting\""
    assert_includes envelope, "data-scheduling-class=\"spot\""
    assert_includes envelope, "data-precedence=\"700\""

    # The row rides inside a <template> so its ids are inert until the page
    # accepts it. A page that filters this session out must not be left holding a
    # second element claiming `ranked_row_<id>`.
    assert_includes envelope, "<template>"
    assert_includes envelope, "id=\"ranked_row_#{session.id}\""
    assert_match(/<template>.*ranked_row_#{session.id}.*<\/template>/m, envelope)
  end

  test "a status change ships both the pill and a membership delivery" do
    session = create_session(scheduling_class: SessionGenesis::SPOT, precedence: 100)

    payloads = ranked_broadcasts { session.update!(status: :running) }

    pill = pill_replacements(payloads).sole
    assert_includes pill, "action=\"replace\""
    assert_includes pill, "target=\"ranked_row_status_#{session.id}\""
    assert_includes pill, "Running"

    envelope = deliveries(payloads).sole
    assert_includes envelope, "data-status=\"running\""
  end

  # The reported bug, at the level it was introduced: archiving used to broadcast
  # a bare `remove`, which every open page obeyed regardless of its filters.
  test "archiving replaces the pill with Trashed and lets the page decide about the row" do
    session = create_session(scheduling_class: SessionGenesis::SPOT, precedence: 100, status: :running)

    payloads = ranked_broadcasts { session.update!(status: :archived) }

    assert_empty payloads.select { |html| html.include?("action=\"remove\"") },
      "the server must not remove a ranked row unilaterally — a page filtered to Archived keeps it"

    pill = pill_replacements(payloads).sole
    assert_includes pill, "Trashed"

    envelope = deliveries(payloads).sole
    assert_includes envelope, "data-status=\"archived\""
  end

  test "a scheduling class change ships a delivery so the row can change sections" do
    session = create_session(scheduling_class: SessionGenesis::SPOT, precedence: 100)

    payloads = ranked_broadcasts { session.update!(scheduling_class: SessionGenesis::PRIORITY) }

    envelope = deliveries(payloads).sole
    assert_includes envelope, "data-scheduling-class=\"priority\""
    # Priority rows have no rank to order by, so the row it ships is the
    # non-draggable variant — the page places it and the two must agree.
    assert_includes envelope, "Demote to spot"
  end

  # A save that satisfies BOTH triggers — the status one, which reaches this
  # broadcast through `broadcast_status_change`, and the scheduling-class one,
  # which reaches it through its own `after_commit` — must still send exactly one
  # envelope. A duplicate is idempotent on the page, but it is two renders and two
  # websocket messages for one event, and the fan-out is per open queue.
  test "changing the status and the class in one save sends one delivery, not two" do
    session = create_session(scheduling_class: SessionGenesis::SPOT, precedence: 100)

    payloads = ranked_broadcasts do
      session.update!(status: :running, scheduling_class: SessionGenesis::PRIORITY)
    end

    envelope = deliveries(payloads).sole
    assert_includes envelope, "data-status=\"running\""
    assert_includes envelope, "data-scheduling-class=\"priority\""
  end

  test "a precedence change alone does not disturb an open queue" do
    session = create_session(scheduling_class: SessionGenesis::SPOT, precedence: 100)

    payloads = ranked_broadcasts { session.update!(precedence: 5000) }

    assert_empty payloads,
      "re-sorting an open queue for a number nobody on that page typed would move rows under a pointer"
  end

  # Status-summary forks are Zimmer's own bookkeeping and are never a row on the
  # dashboard, trash view included.
  test "a status summary fork is never offered to the queue" do
    parent = create_session
    payloads = ranked_broadcasts { create_summary_fork(parent) }

    assert_empty deliveries(payloads)
  end

  # The bug this pins: the exclusion used to sit on the `after_commit`
  # registration alone, which covers creation and nothing else. `pause` and
  # `fail` reach these broadcasts through `broadcast_status_change`, which calls
  # them directly — so every transition a fork makes put an envelope on the
  # stream, and the Ranked view inserted a "Status summary for session #N" row
  # for each fork alive at the time. One long-lived source session had sixteen of
  # them stacked in the spot queue.
  test "a status summary fork's status changes are not offered to the queue either" do
    parent = create_session
    fork = create_summary_fork(parent)

    Session.statuses.each_key do |status|
      next if fork.status == status

      payloads = ranked_broadcasts { fork.update!(status: status) }

      assert_empty stream_targets(payloads),
        "a status-summary fork going #{status} reached the queue's stream"
    end
  end

  # The same fork, on the OTHER path into these broadcasts. A summary fork
  # inherits the source's scheduling class, so it can change class the way any
  # session can — and that is the registration whose guard this change moved.
  test "a status summary fork's scheduling class change is not offered to the queue" do
    parent = create_session
    fork = create_summary_fork(parent)

    payloads = ranked_broadcasts { fork.update!(scheduling_class: SessionGenesis::SPOT) }

    assert_empty stream_targets(payloads)
  end

  def create_summary_fork(parent)
    Session.create!(
      git_root: parent.git_root,
      prompt: "summarize",
      title: "Status summary for session ##{parent.id}",
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => parent.id }
    )
  end
end
