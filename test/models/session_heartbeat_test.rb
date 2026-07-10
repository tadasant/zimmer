# frozen_string_literal: true

require "test_helper"

class SessionHeartbeatTest < ActiveSupport::TestCase
  def make_session(**attrs)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", **attrs)
  end

  test "heartbeat defaults to off with a 60s interval" do
    session = make_session
    assert_not session.heartbeat_enabled
    assert_equal 60, session.heartbeat_interval_seconds
    assert_nil session.heartbeat_last_beat_at
  end

  test "rejects an interval below the minimum" do
    session = make_session
    session.heartbeat_interval_seconds = Session::HEARTBEAT_MIN_INTERVAL_SECONDS - 1
    assert_not session.valid?
    assert_includes session.errors[:heartbeat_interval_seconds].join, "greater than or equal to"
  end

  test "rejects an interval above the maximum" do
    session = make_session
    session.heartbeat_interval_seconds = Session::HEARTBEAT_MAX_INTERVAL_SECONDS + 1
    assert_not session.valid?
  end

  test "heartbeat_active scope only returns enabled sessions" do
    on = make_session(heartbeat_enabled: true)
    off = make_session(heartbeat_enabled: false)
    assert_includes Session.heartbeat_active, on
    assert_not_includes Session.heartbeat_active, off
  end

  test "heartbeat_due scope includes never-beaten enabled sessions" do
    session = make_session(heartbeat_enabled: true, heartbeat_last_beat_at: nil)
    assert_includes Session.heartbeat_due, session
  end

  test "heartbeat_due scope excludes recently-beaten sessions" do
    session = make_session(heartbeat_enabled: true, heartbeat_interval_seconds: 60, heartbeat_last_beat_at: 10.seconds.ago)
    assert_not_includes Session.heartbeat_due, session
  end

  test "heartbeat_due scope includes sessions past their interval" do
    session = make_session(heartbeat_enabled: true, heartbeat_interval_seconds: 60, heartbeat_last_beat_at: 90.seconds.ago)
    assert_includes Session.heartbeat_due, session
  end

  test "heartbeat_due? is false when disabled" do
    session = make_session(heartbeat_enabled: false, heartbeat_last_beat_at: nil)
    assert_not session.heartbeat_due?
  end

  test "heartbeat_due? is true when never beaten and enabled" do
    session = make_session(heartbeat_enabled: true, heartbeat_last_beat_at: nil)
    assert session.heartbeat_due?
  end

  test "heartbeat_due? respects the interval" do
    session = make_session(heartbeat_enabled: true, heartbeat_interval_seconds: 60, heartbeat_last_beat_at: 30.seconds.ago)
    assert_not session.heartbeat_due?
    session.heartbeat_last_beat_at = 90.seconds.ago
    assert session.heartbeat_due?
  end
end
