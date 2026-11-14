# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A session asleep on its own wake-up takes a follow-up immediately and goes
# back to its wait afterwards. Every surface that says "paused" or refuses to
# start a sleeper must say that too — a Live Mode assistant that read only
# "asleep until 22:58Z, will not start it before then" tried start_now, restart
# and force_start in turn and told a driver his answer would come at the wake
# time, when the session had already answered him a minute earlier.
class Sessions::SleeperGuidanceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def asleep_session(metadata: {})
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "work",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      agent_runtime: "claude_code",
      metadata: { "working_directory" => "/tmp/whatever", "agent_root_key" => "zimmer" }.merge(metadata)
    )
    session.sleep!
    Sessions::ScheduleWakeUp.call(session: session, wake_at: 3.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
                                  prompt: "Check on the children")
    session.reload
  end

  def answered!(session)
    session.merge_metadata!(
      Sessions::StopRecord::REASON => Sessions::StopRecord::FOLLOW_UP_RESLEEP,
      Sessions::StopRecord::DETAIL => "Answered a follow-up and went back to the wait it was already on.",
      Sessions::StopRecord::AT => "2026-11-14T22:52:33Z"
    )
    session.reload
  end

  def tool(klass = Mcp::Tools::ActionSession)
    klass.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "a follow-up to a sleeper says it is delivered now and where its answer will be" do
    session = asleep_session

    output = tool.call({ "action" => "follow_up", "session_id" => session.id, "prompt" => "List the parallel work" })

    assert_match(/\*\*Delivered now:\*\* the wake-up does not hold a follow-up back/, output)
    assert_match(/does not wait for its wake-up/, output)
    assert_match(/transcript_last_messages: 2/, output)
    assert_match(/\*\*Its own wake-up:\*\* still armed/, output)
    assert session.reload.paused_until_scheduled_time?, "the wake must survive the follow-up"
  end

  # The one branch where "Delivered now" would be a lie: a turn is underway, so
  # the follow-up is queued behind it rather than delivered.
  test "a follow-up queued behind an underway turn does not claim it was delivered now" do
    session = asleep_session
    Sessions::LiveTurn.stubs(:underway?).returns(true)

    output = tool.call({ "action" => "follow_up", "session_id" => session.id, "prompt" => "List the parallel work" })

    assert_match(/Message queued/, output)
    refute_match(/Delivered now/, output)
    refute_match(/\*\*Its answer:\*\*/, output)
  end

  test "start_now on a sleeper points at follow_up, and at the answer when one was given" do
    session = answered!(asleep_session)

    error = assert_raises(Mcp::ToolError) do
      tool.call({ "action" => "start_now", "session_id" => session.id })
    end

    assert_match(/A pause outranks the queue/, error.message)
    assert_match(/send a `follow_up`/, error.message)
    assert_match(/A follow-up was already delivered to it and answered/, error.message)
    assert_match(/at 2026-11-14T22:52:33Z/, error.message)
    assert session.reload.paused_until_scheduled_time?, "a refusal must leave the wake armed"
  end

  test "restart on a sleeper points at follow_up and leaves the wake armed" do
    session = asleep_session

    error = assert_raises(Mcp::ToolError) do
      tool.call({ "action" => "restart", "session_id" => session.id })
    end

    assert_match(/send a `follow_up`/, error.message)
    refute_match(/already delivered to it and answered/, error.message,
      "no follow-up was answered, so the refusal must not claim one was")
    assert session.reload.paused_until_scheduled_time?
  end

  test "force_start on a sleeper with nothing queued points at follow_up and the answer" do
    session = answered!(asleep_session)

    error = assert_raises(Mcp::ToolError) do
      tool.call({ "action" => "force_start", "session_id" => session.id })
    end

    assert_match(/no turn queued for a worker/, error.message)
    assert_match(/send a `follow_up`/, error.message)
    assert_match(/already delivered to it and answered/, error.message)
  end

  test "get_session and the search row say an answered follow-up was answered" do
    session = answered!(asleep_session)

    detail = tool(Mcp::Tools::GetSession).call({ "id" => session.id })
    assert_match(/\*\*Dormant because:\*\* `follow_up_resleep`.*already delivered to it and answered/, detail)

    row = tool(Mcp::Tools::QuickSearchSessions).call({ "id" => session.id })
    assert_match(/\*\*Paused:\*\* yes/, row)
    assert_match(/`follow_up` wakes it for one turn immediately/, row)
    assert_match(/\*\*Last follow-up:\*\* A follow-up was already delivered to it and answered/, row)
  end

  test "a session that is neither asleep nor just answered gets no tail" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "work", status: :needs_input,
                              session_id: SecureRandom.uuid, agent_runtime: "claude_code",
                              metadata: { "agent_root_key" => "zimmer" })

    assert_equal "", Sessions::SleeperGuidance.refusal_tail(session)
  end
end
