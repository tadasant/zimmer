# frozen_string_literal: true

require "test_helper"

# "Pause Until" (a one-time wake armed against a session) outranks every reason
# Zimmer has to start that session early.
#
# Two features landed 45 minutes apart: "Pause Until", which sleeps a session and
# arms a one-time wake, and the ranked spot queue, which replaced the per-session
# quota timers with one `quota_available` edge that spawns a fleet-maintenance
# session to decide — in precedence order — who runs. Neither knew about the
# other. A paused session is `waiting`, which is exactly the state every automated
# resume sweep selects on, and precedence is read from a column that says nothing
# about whether the session asked to be left alone.
#
# The contract these tests pin: a session with a pending future wake is dormant to
# EVERY automated starter — the spot-ceiling sweep, the auth-outage un-park, and
# the fresh-start job — regardless of its precedence or its scheduling class. It
# wakes on its own schedule and on nothing else.
class PauseUntilStackingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def wake_at(offset = 3.hours)
    offset.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S")
  end

  # A session that has run, come to rest, and been put to sleep by an automated
  # sweep — the population every resume path below selects from.
  def dormant_session(genesis:, precedence: 0, metadata: {})
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "work",
      genesis: genesis,
      precedence: precedence,
      status: :needs_input,
      session_id: SecureRandom.uuid,
      agent_runtime: "claude_code",
      # A real session resolves to a catalog agent root, and the wake trigger
      # carries it: Trigger#create_session! heals its root before firing, so a
      # session without one arms a wake that cannot fire.
      metadata: { "working_directory" => "/tmp/whatever", "agent_root_key" => "zimmer" }.merge(metadata)
    )
    session.sleep!
    session.reload
  end

  def action_session_tool
    Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  def pause_until!(session, at = wake_at)
    Sessions::ScheduleWakeUp.call(session: session, wake_at: at, prompt: "Resume after the pause")
  end

  # === The spot-ceiling sweep (SpotCeilingSweepJob, every 5 minutes) ===

  test "the spot ceiling sweep leaves a paused session asleep even when the gate reopens" do
    session = dormant_session(
      genesis: SessionGenesis::GITHUB_ISSUE,
      precedence: 100_000,
      metadata: {
        SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
        SpotSessionPause::PAUSED_AT => 1.hour.ago.utc.iso8601,
        "paused_by" => SpotSessionPause::PAUSED_BY
      }
    )
    trigger = pause_until!(session)
    assert session.reload.waiting?, "precondition: the pause leaves the session waiting"

    AppSetting.editable.update!(spot_gating_enabled: false)
    result = SpotSessionPause.sweep!

    assert_equal 0, result.resumed, "a paused session must not be resumed by the ceiling sweep"
    assert session.reload.waiting?, "expected the session to stay asleep, got #{session.status}"
    assert Trigger.exists?(trigger.id), "the pause must survive the sweep"
    assert session.awaiting_scheduled_wake?, "the wake must still be armed"
  end

  test "the spot ceiling sweep leaves a paused session asleep even after promotion to priority" do
    session = dormant_session(
      genesis: SessionGenesis::WEB_UI,
      precedence: 100_000,
      metadata: {
        SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
        SpotSessionPause::PAUSED_AT => 1.hour.ago.utc.iso8601,
        "paused_by" => SpotSessionPause::PAUSED_BY
      }
    )
    pause_until!(session)
    refute session.reload.spot?, "precondition: this session is priority-classified"

    result = SpotSessionPause.sweep!

    assert_equal 0, result.resumed, "priority does not outrank a pause"
    assert session.reload.waiting?, "expected the session to stay asleep, got #{session.status}"
  end

  # === The auth-outage un-park (QuotaResetCheckerJob, every 15 minutes) ===

  test "the auth outage sweep leaves a paused priority session asleep" do
    account = ClaudeAccount.create!(email: "pause-stacking@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    assert account.persisted?

    session = dormant_session(
      genesis: SessionGenesis::WEB_UI,
      precedence: 100_000,
      metadata: {
        "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
        "auth_outage_parked_at" => 1.hour.ago.utc.iso8601
      }
    )
    trigger = pause_until!(session)

    resumed = AuthOutageParkService.wake_parked_sessions!

    assert_equal 0, resumed, "a paused session must not be un-parked early"
    assert session.reload.waiting?, "expected the session to stay asleep, got #{session.status}"
    assert Trigger.exists?(trigger.id),
      "the pause must survive the sweep — resume! would have destroyed it silently"
  end

  # === The fresh-start job (a spot hold re-check, a fleet slot opening) ===

  test "the fresh-start job still starts a session whose only armed wake has come due" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    pause_until!(session, wake_at(1.hour))

    # The pause is a DEFERRAL. Past its time the wake is no longer "still ahead",
    # so the guard stops applying and the ordinary start path takes over — this is
    # what keeps the fix from being a way to strand a session forever.
    travel_to 2.hours.from_now do
      refute session.reload.awaiting_scheduled_wake?,
        "a wake whose moment has passed is not something the session is still waiting on"
    end
  end

  # The other half of the deferral: the wake itself still fires and still starts
  # the session. A guard that made a paused session unstartable by EVERYTHING —
  # including its own wake — would pass every test above and be a worse bug.
  test "the wake fires on time and starts the session it paused" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    trigger = pause_until!(session, wake_at(1.hour))
    assert session.reload.waiting?

    travel_to 2.hours.from_now do
      assert_enqueued_with(job: AgentSessionJob) do
        ScheduleTriggerJob.perform_now
      end
    end

    assert session.reload.running?, "expected the wake to start the session, got #{session.status}"
    refute Trigger.exists?(trigger.id),
      "a spent one-time wake is auto-deleted, so it cannot re-sleep the session mid-work"
  end

  # === The selector's own start path (action_session restart) ===

  # The awaken-waiting-sessions skill hands out compute with `action_session
  # restart`. That path resumes the session BEFORE it enqueues anything, and
  # `resume`'s cancel_pending_one_time_wake_triggers callback consumes the pause on
  # the way past — so a guard further down the stack arrives after the pause is
  # already gone. It has to refuse here.
  test "action_session restart refuses a paused session and says to take the next candidate" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    trigger = pause_until!(session)

    error = assert_raises(Mcp::ToolError) do
      action_session_tool.call({ "action" => "restart", "session_id" => session.id })
    end

    assert_match(/does not start early/, error.message)
    assert_match(/skip it and take the next candidate/i, error.message)
    assert session.reload.waiting?, "expected the session to stay asleep, got #{session.status}"
    assert Trigger.exists?(trigger.id), "refusing must leave the pause armed"
  end

  test "action_session restart still works on a session that is merely parked" do
    session = dormant_session(
      genesis: SessionGenesis::GITHUB_ISSUE,
      precedence: 100_000,
      metadata: { "runtime_started" => true }
    )

    action_session_tool.call({ "action" => "restart", "session_id" => session.id })

    assert session.reload.running?, "an unpaused parked session must still be startable"
  end

  # The selector is partly an AGENT reading the ranked queue through this tool. The
  # guards above make a paused session unstartable whatever it decides — but a
  # queue listing that shows no difference between "paused until 3pm" and "queued
  # behind the quota gate" makes it burn a turn discovering that.
  test "the ranked queue listing marks a paused session" do
    paused = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    pause_until!(paused)
    queued = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 50)

    tool = Mcp::Tools::QuickSearchSessions.new(context: Mcp::Context.new(tool_groups: "sessions"))
    output = tool.call({ "status" => "waiting", "order" => "precedence", "per_page" => 100 })

    paused_block = output.split("### ").find { |block| block.start_with?("#{paused.title} (ID: #{paused.id})") }
    queued_block = output.split("### ").find { |block| block.start_with?("#{queued.title} (ID: #{queued.id})") }

    assert paused_block, "the paused session must still be listed, not hidden from the queue"
    assert_match(/\*\*Paused:\*\* yes/, paused_block)
    assert_match(/Skip it and take the next candidate/, paused_block)
    refute_match(/\*\*Paused:\*\* yes/, queued_block.to_s,
      "a session merely queued behind the gate must not be reported as paused")
  end

  test "the fresh-start job stands down for a paused session instead of starting it" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "work",
      genesis: SessionGenesis::GITHUB_ISSUE,
      precedence: 100_000,
      status: :needs_input,
      session_id: SecureRandom.uuid,
      agent_runtime: "claude_code",
      metadata: { "agent_root_key" => "zimmer" }
    )
    session.sleep!
    pause_until!(session.reload)

    assert_no_enqueued_jobs only: AgentSessionJob do
      AgentSessionJob.new.perform(session.id)
    end

    assert session.reload.waiting?, "expected the session to stay asleep, got #{session.status}"
    assert session.awaiting_scheduled_wake?, "the wake must still be armed"
  end
end
