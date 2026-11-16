# frozen_string_literal: true

require "test_helper"

class CycleTimes::LaneBuilderTest < ActiveSupport::TestCase
  T = Time.utc(2026, 11, 1, 9)
  Change = CycleTimes::StateLog::Change
  Event = CycleTimes::TranscriptEvents::Event
  Types = OpenTranscript::Types

  def change(at, kind) = Change.new(T + at, kind, kind.to_s)
  def ev(at, type, id: nil, tool: nil, args: {}) = Event.new(T + at, type, id, tool, args)
  def call(at, id, tool, args = {}) = ev(at, Types::TOOL_CALL, id: id, tool: tool, args: args)
  def result(at, id) = ev(at, Types::TOOL_RESULT, id: id)

  def build(span_end:, changes:, events: [], **opts)
    CycleTimes::LaneBuilder.new(span_start: T, span_end: T + span_end, changes: changes, events: events, **opts).build
  end

  def summary(segments) = segments.map { |s| [ s.start - T, s.finish - T, s.category ] }

  def assert_tiles(segments, span_end)
    assert_equal 0, segments.first.start - T
    assert_equal span_end, segments.last.finish - T
    segments.each_cons(2) { |a, b| assert_equal a.finish, b.start }
  end

  test "a turn splits into startup, inference, the tool's own category, and wind-down" do
    segments = build(
      span_end: 100,
      changes: [ change(10, :running), change(90, :needs_input) ],
      events: [
        ev(15, Types::USER_MESSAGE), call(30, "a", "Bash", { "command" => "bin/rails test" }), result(60, "a"),
        ev(80, Types::ASSISTANT_MESSAGE)
      ]
    )

    assert_tiles(segments, 100)
    assert_equal [
      [ 0, 10, "wait_worker_queue" ], [ 10, 15, "turn_startup" ], [ 15, 30, "inference" ], [ 30, 60, "local_io" ],
      [ 60, 80, "inference" ], [ 80, 90, "unattributed" ], [ 90, 100, "unattributed" ]
    ], summary(segments)
  end

  test "parallel tool calls charge each stretch to the call whose result closes it" do
    segments = build(
      span_end: 50,
      changes: [ change(0.5, :running), change(49, :needs_input) ],
      events: [
        ev(1, Types::USER_MESSAGE),
        call(5, "a", "Read", { "file_path" => "x" }), call(5, "b", "WebFetch", { "url" => "u" }),
        result(7, "a"), result(40, "b"), ev(45, Types::ASSISTANT_MESSAGE)
      ]
    )

    assert_includes summary(segments), [ 5, 7, "local_io" ]
    assert_includes summary(segments), [ 7, 40, "network" ]
  end

  test "a sleep takes the category of the wake its turn armed" do
    wake = { "prompt" => "CI wake 1 on https://github.com/a/b/pull/1" }
    segments = build(
      span_end: 1000,
      changes: [ change(1, :running), change(20, :needs_input), change(21, :sleeping), change(900, :queued), change(950, :running) ],
      events: [ ev(2, Types::USER_MESSAGE), call(10, "w", "mcp__zimmer-self-session__wake_me_up_later", wake), result(11, "w") ]
    )

    assert_includes summary(segments), [ 21, 900, "wait_ci" ]
    assert_includes summary(segments), [ 900, 950, "wait_worker_queue" ]
    assert_tiles(segments, 1000)
  end

  test "a child watch beats its backstop wake" do
    segments = build(
      span_end: 500,
      changes: [ change(1, :running), change(20, :needs_input), change(21, :sleeping) ],
      events: [
        ev(2, Types::USER_MESSAGE),
        call(5, "a", "mcp__zimmer__wake_me_up_when_session_changes_state", { "session_ids" => [ 9 ] }), result(6, "a"),
        call(7, "b", "mcp__zimmer__wake_me_up_later", { "prompt" => "Backstop" }), result(8, "b")
      ]
    )

    assert_includes summary(segments), [ 21, 500, "wait_child" ]
  end

  test "spot holds and quota parks color the queued and asleep time after them" do
    segments = build(
      span_end: 400,
      changes: [ change(5, :spot_hold), change(100, :running), change(150, :needs_input), change(151, :quota_park),
                 change(152, :sleeping), change(300, :queued), change(350, :running) ]
    )

    assert_equal [ 0, 5, "wait_worker_queue" ], summary(segments).first
    assert_includes summary(segments), [ 5, 100, "wait_spot_hold" ]
    # Asleep and then queued under the same park: one stretch.
    assert_includes summary(segments), [ 152, 350, "wait_quota_park" ]
  end

  test "needs_input splits into a wait on live children and the rest" do
    segments = build(
      span_end: 100,
      changes: [ change(1, :running), change(10, :needs_input) ],
      child_windows: [ [ T + 20, T + 40 ], [ T + 30, T + 60 ] ],
      holds_pr: true
    )

    assert_equal [ [ 10, 20, "wait_merge_gate" ], [ 20, 60, "wait_child" ], [ 60, 100, "wait_merge_gate" ] ],
                 summary(segments).select { |s| s[0] >= 10 }
  end

  test "an elicitation pauses the open call; the unblocked turn resumes it without a second startup" do
    segments = build(
      span_end: 100,
      changes: [ change(1, :running), change(10, :elicitation), change(60, :resumed), change(90, :needs_input) ],
      events: [ ev(2, Types::USER_MESSAGE), call(5, "a", "mcp__github__merge", {}), result(61, "a"), ev(70, Types::ASSISTANT_MESSAGE) ]
    )

    assert_includes summary(segments), [ 10, 60, "wait_human" ]
    assert_includes summary(segments), [ 60, 61, "network" ]
    assert_not(summary(segments).any? { |from, _, category| category == "turn_startup" && from >= 60 })
    assert_tiles(segments, 100)
  end

  test "a call that never returns stops absorbing the turn once the model generates again" do
    segments = build(
      span_end: 100,
      changes: [ change(1, :running), change(90, :needs_input) ],
      events: [
        ev(2, Types::USER_MESSAGE), call(5, "a", "Bash", { "command" => "gh pr checks 1 --watch" }),
        call(30, "b", "Read", { "file_path" => "x" }), result(31, "b"), ev(60, Types::ASSISTANT_MESSAGE)
      ]
    )

    assert_includes summary(segments), [ 5, 30, "wait_ci" ]
    assert_includes summary(segments), [ 31, 60, "inference" ]
    assert_includes summary(segments), [ 60, 90, "unattributed" ]
  end

  test "the display cut stays within its cap on mixed long and short segments" do
    t = T
    segments = []
    1_400.times do
      segments << CycleTimes::LaneBuilder::Segment.new(t, t + 1, "inference", "gen")
      segments << CycleTimes::LaneBuilder::Segment.new(t + 1, t + 1.001, "local_io", "read")
      t += 1.001
    end

    shown = CycleTimes::LaneBuilder.for_display(segments, max: 300)

    assert_operator shown.size, :<=, 300
    assert_equal segments.first.start, shown.first.start
    assert_equal segments.last.finish, shown.last.finish
    shown.each_cons(2) { |a, b| assert_equal a.finish, b.start }
  end

  test "a tool still open when the session ends keeps its category to the end" do
    segments = build(
      span_end: 30,
      changes: [ change(1, :running) ],
      events: [ ev(2, Types::USER_MESSAGE), call(10, "a", "mcp__zimmer-self-session__action_session", { "action" => "archive" }) ]
    )

    assert_equal [ 10, 30, "network" ], summary(segments).last
  end

  test "a huge lane is cut down for display without losing its span" do
    events = [ ev(0.5, Types::USER_MESSAGE) ]
    3_000.times { |i| events << call(1 + i, "r#{i}", "Read", { "file_path" => "f#{i}" }) << result(1.5 + i, "r#{i}") }
    segments = build(span_end: 3_100, changes: [ change(0.1, :running) ], events: events)
    assert_in_delta 1_500.0, segments.select { |s| s.category == "local_io" }.sum(&:seconds), 0.01

    shown = CycleTimes::LaneBuilder.for_display(segments)

    assert_operator shown.size, :<=, CycleTimes::LaneBuilder::MAX_SEGMENTS
    assert_tiles(shown, 3_100)
    assert_match "short segments", shown.find { |s| s.detail.include?("short") }.detail
  end
end
