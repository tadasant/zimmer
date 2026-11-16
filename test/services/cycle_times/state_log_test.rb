# frozen_string_literal: true

require "test_helper"

# StateLog keys on the leading words of timeline lines other code writes. These
# tests pin the parser to the writers' source, so rewording a log line fails here
# rather than silently turning queue time into unattributed time.
class CycleTimes::StateLogTest < ActiveSupport::TestCase
  WRITERS = {
    "app/models/concerns/session_state_machine.rb" => [
      "Turn started on a worker", "Session sleeping, waiting for scheduled wake-up", "Session paused, waiting for input",
      "Session resumed — its turn is queued for a worker", "Session blocked on MCP elicitation",
      "Session unblocked from MCP elicitation", "Session failed:", "Session moved to trash by ",
      "Session restored from trash to waiting", "Session restored from trash to needs_input"
    ],
    "app/services/spot_session_hold.rb" => [ "Spot session held " ],
    "app/services/auth_outage_park_service.rb" => [ "Quota exceeded across all", "login available." ],
    "app/services/provider_quota_wall_park.rb" => [ "Provider quota wall" ]
  }.freeze

  test "the strings the parser keys on still exist in their writers" do
    WRITERS.each do |path, strings|
      source = Rails.root.join(path).read
      strings.each { |string| assert_includes source, string, "#{path} no longer writes #{string.inspect}" }
    end
  end

  test "parses transitions and overlays in time order" do
    t = Time.utc(2026, 11, 1)
    logs = [
      Log.new(created_at: t + 3, content: "[State Machine] Session paused, waiting for input"),
      Log.new(created_at: t + 1, content: "[State Machine] Turn started on a worker"),
      Log.new(created_at: t + 4, content: "Spot session held before its next turn: busy"),
      Log.new(created_at: t + 5, content: "Quota exceeded across all Claude Code accounts. Every account..."),
      Log.new(created_at: t + 6, content: "[State Machine] Session moved to trash by session #4 via the MCP API — 1 PR"),
      Log.new(created_at: t + 7, content: "some unrelated runtime output")
    ]

    changes = CycleTimes::StateLog.parse(logs)

    assert_equal %i[running needs_input spot_hold quota_park archived], changes.map(&:kind)
    assert_equal [ "session #4 via the MCP API" ], CycleTimes::StateLog.archive_actors(changes)
  end

  test "archive actors classify by surface" do
    {
      "session #12 via the self-session MCP server" => :agent,
      "session #12 via the MCP API" => :agent,
      "an undeclared MCP API caller" => :agent,
      "an undeclared MCP API caller (bulk)" => :agent,
      "session #12 via the MCP API (bulk)" => :agent,
      "an undeclared self-session MCP server caller" => :agent,
      "the REST API" => :agent,
      "the REST API (bulk)" => :agent,
      "a user in the web UI" => :human,
      "a user in the web UI (bulk action)" => :human,
      "session #3 via the Live Mode assistant" => :human,
      "an undeclared Live Mode assistant caller" => :human,
      "Zimmer's stale-session sweep (untouched for 7 days)" => :system,
      "an unrecorded caller" => :unrecorded,
      "" => :unrecorded
    }.each { |phrase, expected| assert_equal expected, CycleTimes::ArchiveActor.classify(phrase), phrase }
  end
end
