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
    assert session.paused_until_scheduled_time?, "the session must still be under its pause"
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

  # The pause is a DEFERRAL, and its EXPIRY is what makes that true. Past its time
  # the wake is no longer "still ahead", so every guard stops applying and the
  # session is an ordinary candidate again — reachable by the spot sweep as well as
  # by its own wake. This is what keeps the fix from being a way to strand work.
  test "the guards stop applying once the pause has expired" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    pause_until!(session, wake_at(1.hour))
    assert session.reload.paused_until_scheduled_time?

    travel_to 2.hours.from_now do
      refute session.reload.paused_until_scheduled_time?,
        "a wake whose moment has passed is not a pause the session is still under"

      assert_nothing_raised do
        action_session_tool.call({ "action" => "restart", "session_id" => session.id })
      end
      assert session.reload.running?, "expected an expired pause to let a restart through"
    end
  end

  # The other half of the deferral: the wake itself still fires and still starts
  # the session. A guard that made a paused session unstartable by EVERYTHING —
  # including its own wake — would pass every test above and be a worse bug.
  #
  # A PRIORITY session, deliberately: priority work is never gated on quota, so
  # this pins "the wake starts it" without also asserting anything about what the
  # spot gate does to a spot session's turn. That is the spot queue's decision, not
  # the pause's — see the test below.
  test "the wake fires on time and starts the priority session it paused" do
    session = dormant_session(genesis: SessionGenesis::WEB_UI, precedence: 100_000)
    trigger = pause_until!(session, wake_at(1.hour))
    assert session.reload.waiting?
    refute session.spot?, "precondition: this session is priority-classified"

    travel_to 2.hours.from_now do
      assert_enqueued_with(job: AgentSessionJob) do
        ScheduleTriggerJob.perform_now
      end
    end

    assert session.reload.running?, "expected the wake to start the session, got #{session.status}"
    refute Trigger.exists?(trigger.id),
      "a spent one-time wake is auto-deleted, so it cannot re-sleep the session mid-work"
  end

  # A pause is a FLOOR, not a promotion. "Not before 3pm" does not mean "and then
  # run regardless of the queue" — the spot queue stays the scheduler for spot
  # work, so a fired wake hands the session to it rather than past it.
  #
  # Concretely: the pause guard reads `follow_up_prompt.blank?`, so the turn the
  # wake delivers is NOT refused by it and reaches the spot gate as an ordinary
  # turn. This test pins that the guard yields rather than pre-empting, which is
  # the property the gate's own behaviour is layered on.
  test "a fired wake is not refused by the pause guard — it goes on to the spot gate" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    pause_until!(session, wake_at(1.hour))
    assert session.spot?, "precondition: this session is spot-classified"

    travel_to 2.hours.from_now do
      ScheduleTriggerJob.perform_now
    end

    # The wake delivered its prompt rather than being stood down on: the session
    # left `waiting`, which only the delivery does.
    refute session.reload.waiting?,
      "the wake's own turn must not be refused by the pause guard"
  end

  # A Spot Queue park arms NO wake, so none of the guards may see it — the whole
  # point of that park is that the ceiling sweep resumes it.
  test "a spot queue park is untouched by the pause guards and still resumed by the sweep" do
    session = dormant_session(
      genesis: SessionGenesis::GITHUB_ISSUE,
      precedence: 100_000,
      metadata: {
        SpotSessionPause::PAUSED_REASON => SpotSessionPause::QUEUED_REASON,
        SpotSessionPause::PAUSED_AT => 1.hour.ago.utc.iso8601,
        "paused_by" => SpotSessionPause::PAUSED_BY
      }
    )
    refute session.reload.paused_until_scheduled_time?,
      "a spot queue park arms no wake, so it is not a wall-clock pause"

    AppSetting.editable.update!(spot_gating_enabled: false)
    result = SpotSessionPause.sweep!

    assert_equal 1, result.resumed, "the spot queue is the scheduler for this park — it must resume it"
    assert session.reload.running?
  end

  # An `ao_event` watcher has no time component: if the watched session fails or is
  # archived, it is "still ahead" forever. Blocking a START on that would put a
  # session permanently beyond every automated path on one dead watcher, so the
  # start guards read the narrower predicate.
  test "an event watcher is not a wall-clock pause and does not block a start" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    watched = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE)
    Trigger.create!(
      name: "Watch session ##{watched.id}",
      agent_root_name: "zimmer",
      prompt_template: "The watched session moved",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event",
          configuration: { "event_name" => "session_archived", "watched_session_id" => watched.id } }
      ]
    )

    assert session.reload.awaiting_scheduled_wake?, "it IS resting on purpose — a refresh must not nudge it"
    refute session.paused_until_scheduled_time?, "but it is not paused until a time, so a start is allowed"

    assert_nothing_raised do
      action_session_tool.call({ "action" => "restart", "session_id" => session.id })
    end
    assert session.reload.running?
  end

  # === pending_wake_at, the value every refusal message quotes ===

  test "pending_wake_at reports the earliest armed wake, in the timezone it was set in" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE)
    later = 5.hours.from_now
    sooner = 2.hours.from_now

    Sessions::ScheduleWakeUp.call(session: session, prompt: "later",
      wake_at: later.utc.strftime("%Y-%m-%dT%H:%M:%S"))
    Sessions::ScheduleWakeUp.call(session: session.reload, prompt: "sooner",
      wake_at: sooner.in_time_zone("America/New_York").strftime("%Y-%m-%dT%H:%M:%S"),
      timezone: "America/New_York")

    assert_in_delta sooner.to_i, session.reload.pending_wake_at.to_i, 60
    assert_match(/paused until #{Regexp.escape(session.pending_wake_at.utc.iso8601)}/, session.pending_wake_phrase)
  end

  test "pending_wake_at is nil when nothing wall-clock is armed" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE)

    assert_nil session.pending_wake_at
    assert_equal "it is asleep on a pending wake-up", session.pending_wake_phrase
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

  # The deliberate exception: a caller addressing this session directly is taking it
  # over, not working a queue. `follow_up` is that caller, and consuming the now-moot
  # wake is the documented behaviour of `resume` — pinned so the guards above cannot
  # be widened into it by accident.
  test "a follow_up addressed at a paused session still takes it over" do
    session = dormant_session(genesis: SessionGenesis::GITHUB_ISSUE, precedence: 100_000)
    trigger = pause_until!(session)

    action_session_tool.call(
      { "action" => "follow_up", "session_id" => session.id, "prompt" => "Actually, do it now" }
    )

    assert session.reload.running?, "a direct follow-up must not be refused, got #{session.status}"
    assert trigger.reload.trigger_conditions.sole.last_triggered_at.present?,
      "taking the session over consumes its pending wake, so it cannot fire into live work"
    refute session.paused_until_scheduled_time?
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
    assert session.paused_until_scheduled_time?, "the session must still be under its pause"
  end
end
