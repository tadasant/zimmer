require "test_helper"
require "mocha/minitest"

# Sessions::UpdateHeartbeat is the single writer behind all three surfaces (the
# web heart popout, PATCH /api/v1/sessions/:id/heartbeat, and the `set_heartbeat`
# MCP action). What matters here is that an unreadable value is refused rather
# than guessed at, that the interval range is enforced by the service itself,
# that a call naming nothing is distinguishable from one naming something
# unreadable, and that writing the settings touches nothing else on the session.
class Sessions::UpdateHeartbeatTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }.merge(attrs))
  end

  test "enables the heartbeat" do
    session = make_session(heartbeat_enabled: false)

    Sessions::UpdateHeartbeat.call(session: session, enabled: true)

    assert session.reload.heartbeat_enabled
  end

  test "disables the heartbeat" do
    session = make_session(heartbeat_enabled: true)

    Sessions::UpdateHeartbeat.call(session: session, enabled: false)

    assert_not session.reload.heartbeat_enabled
  end

  test "casts a stringy boolean" do
    session = make_session(heartbeat_enabled: false)

    Sessions::UpdateHeartbeat.call(session: session, enabled: "true")

    assert session.reload.heartbeat_enabled
  end

  # A blank `enabled` is the one value ActiveModel cannot read, and refusing it
  # is what keeps a nil away from the NOT NULL column.
  test "refuses a blank enabled" do
    session = make_session(heartbeat_enabled: false)

    error = assert_raises(Sessions::UpdateHeartbeat::Error) do
      Sessions::UpdateHeartbeat.call(session: session, enabled: "")
    end
    assert_match(/enabled must be a boolean/, error.message)
    assert_not session.reload.heartbeat_enabled
  end

  # ActiveModel's boolean cast answers false only for its FALSE_VALUES and true
  # for every other non-blank string. Pinned so the service cannot tighten it by
  # accident — that is ActiveModel's contract, not a choice this service makes.
  test "reads a non-blank unrecognized string as true" do
    session = make_session(heartbeat_enabled: false)

    Sessions::UpdateHeartbeat.call(session: session, enabled: "maybe")

    assert session.reload.heartbeat_enabled
  end

  test "sets the interval" do
    session = make_session

    Sessions::UpdateHeartbeat.call(session: session, interval_seconds: 300)

    assert_equal 300, session.reload.heartbeat_interval_seconds
  end

  test "accepts a stringy integer interval" do
    session = make_session

    Sessions::UpdateHeartbeat.call(session: session, interval_seconds: "300")

    assert_equal 300, session.reload.heartbeat_interval_seconds
  end

  test "accepts the interval bounds themselves" do
    session = make_session

    Sessions::UpdateHeartbeat.call(session: session, interval_seconds: Session::HEARTBEAT_MIN_INTERVAL_SECONDS)
    assert_equal Session::HEARTBEAT_MIN_INTERVAL_SECONDS, session.reload.heartbeat_interval_seconds

    Sessions::UpdateHeartbeat.call(session: session, interval_seconds: Session::HEARTBEAT_MAX_INTERVAL_SECONDS)
    assert_equal Session::HEARTBEAT_MAX_INTERVAL_SECONDS, session.reload.heartbeat_interval_seconds
  end

  test "refuses an interval below the floor and names the range" do
    session = make_session(heartbeat_interval_seconds: 60)

    error = assert_raises(Sessions::UpdateHeartbeat::Error) do
      Sessions::UpdateHeartbeat.call(session: session, interval_seconds: 1)
    end
    assert_match(/between #{Session::HEARTBEAT_MIN_INTERVAL_SECONDS} and #{Session::HEARTBEAT_MAX_INTERVAL_SECONDS}/, error.message)
    assert_equal 60, session.reload.heartbeat_interval_seconds
  end

  test "refuses an interval above the ceiling" do
    session = make_session(heartbeat_interval_seconds: 60)

    assert_raises(Sessions::UpdateHeartbeat::Error) do
      Sessions::UpdateHeartbeat.call(session: session, interval_seconds: Session::HEARTBEAT_MAX_INTERVAL_SECONDS + 1)
    end
    assert_equal 60, session.reload.heartbeat_interval_seconds
  end

  # ActiveRecord's integer cast reads "300abc" as 300 and "abc" as 0. The service
  # is stricter, because a truncated interval is a silently wrong cadence.
  test "refuses a half-numeric interval instead of truncating it" do
    session = make_session(heartbeat_interval_seconds: 60)

    error = assert_raises(Sessions::UpdateHeartbeat::Error) do
      Sessions::UpdateHeartbeat.call(session: session, interval_seconds: "300abc")
    end
    assert_match(/interval_seconds must be an integer/, error.message)
    assert_equal 60, session.reload.heartbeat_interval_seconds
  end

  test "refuses a negative interval" do
    session = make_session(heartbeat_interval_seconds: 60)

    assert_raises(Sessions::UpdateHeartbeat::Error) do
      Sessions::UpdateHeartbeat.call(session: session, interval_seconds: "-300")
    end
    assert_equal 60, session.reload.heartbeat_interval_seconds
  end

  test "sets both settings in one write" do
    session = make_session(heartbeat_enabled: false, heartbeat_interval_seconds: 60)

    Sessions::UpdateHeartbeat.call(session: session, enabled: true, interval_seconds: 120)

    session.reload
    assert session.heartbeat_enabled
    assert_equal 120, session.heartbeat_interval_seconds
  end

  test "a bad interval leaves a good enabled unwritten" do
    session = make_session(heartbeat_enabled: false, heartbeat_interval_seconds: 60)

    assert_raises(Sessions::UpdateHeartbeat::Error) do
      Sessions::UpdateHeartbeat.call(session: session, enabled: true, interval_seconds: 1)
    end

    session.reload
    assert_not session.heartbeat_enabled
    assert_equal 60, session.heartbeat_interval_seconds
  end

  test "refuses a call that names no setting" do
    session = make_session

    error = assert_raises(Sessions::UpdateHeartbeat::MissingSetting) { Sessions::UpdateHeartbeat.call(session: session) }
    assert_match(/at least one of enabled or interval_seconds/, error.message)
  end

  # MissingSetting is a subclass, so a surface that only cares that the call was
  # refused can still rescue Error and catch both.
  test "MissingSetting is an Error" do
    session = make_session

    assert_raises(Sessions::UpdateHeartbeat::Error) { Sessions::UpdateHeartbeat.call(session: session) }
  end

  # An unreadable value is NOT a missing one: the REST API classifies the two
  # differently in its `error` field, so they have to stay distinguishable here.
  test "an unreadable value raises Error and not MissingSetting" do
    session = make_session

    error = assert_raises(Sessions::UpdateHeartbeat::Error) do
      Sessions::UpdateHeartbeat.call(session: session, enabled: "")
    end
    assert_not_kind_of Sessions::UpdateHeartbeat::MissingSetting, error
  end

  test "touches nothing but the two heartbeat columns" do
    session = make_session(heartbeat_enabled: false, status: :needs_input)
    before = session.attributes.except("heartbeat_enabled", "heartbeat_interval_seconds", "updated_at")

    Sessions::UpdateHeartbeat.call(session: session, enabled: true, interval_seconds: 120)

    after = session.reload.attributes.except("heartbeat_enabled", "heartbeat_interval_seconds", "updated_at")
    assert_equal before, after
  end

  test "does not beat the heartbeat" do
    session = make_session(heartbeat_enabled: false, heartbeat_last_beat_at: nil)

    Sessions::UpdateHeartbeat.call(session: session, enabled: true)

    assert_nil session.reload.heartbeat_last_beat_at
  end

  test "returns the session" do
    session = make_session

    assert_equal session, Sessions::UpdateHeartbeat.call(session: session, enabled: true)
  end
end
