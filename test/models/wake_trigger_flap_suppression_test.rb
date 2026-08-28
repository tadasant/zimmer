# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# The incident this file exists for.
#
# Router session #9964 routed one piece of work to child #9966 and ran the
# standard wait loop: a `session_needs_input` / `session_failed` /
# `session_archived` watcher on the child plus a `wake_me_up_later` deadline.
# The child was healthy. It had opened a PR and gone to sleep on its own bounded
# self-wake, and every time that wake fired it took a turn and slept again. Each
# of those turn boundaries crossed `needs_input` for microseconds on its way back
# to `waiting`, and each one fired the router's watcher: four wakes in 25 minutes,
# each costing a full agent turn plus the re-registration of the sibling wakes the
# fire had destroyed.
#
# So the flap generator is a healthy, self-waking child, and the subscription is
# to an event that is emitted at every turn boundary rather than when the session
# comes to rest. These tests drive that shape end to end — through the real
# `pause` callback and the real firing job — and assert that a boundary the
# session leaves again does not wake anybody, while a genuine rest still does.
class WakeTriggerFlapSuppressionTest < ActiveJob::TestCase
  setup do
    # The wake trigger resumes an existing session rather than spawning one, but
    # Trigger#create_session! still resolves the agent root and the spawn path on
    # its way there.
    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:perform_later)

    # Isolate: fixtures carry enabled broadcast ao_event triggers that would
    # otherwise spawn sessions on every transition here.
    Trigger.where(status: "enabled").find_each do |trigger|
      trigger.update!(status: "disabled") if trigger.trigger_conditions.ao_event.exists?
    end

    @watcher = create_session(status: :needs_input, prompt: "Router")
    @watched = create_session(status: :running, prompt: "Child", is_autonomous: true)
  end

  # === The flap itself ===

  test "a watched session that sleeps on its own wake at the turn boundary does not wake its watcher" do
    # The child schedules its own bounded self-wake while running, exactly as the
    # open-pr skill's terminal step does. That records a sleep intent, so the
    # `needs_input` this pause crosses is a boundary and not a rest.
    schedule_self_wake(@watched)
    trigger = watch(@watched, "session_needs_input")

    pause_and_settle(@watched)

    assert @watched.reload.waiting?, "the child went back to sleep, which is the whole point"
    assert @watcher.reload.needs_input?, "the watcher must not have been resumed by a turn boundary"
    assert Trigger.exists?(trigger.id), "the watcher's wake must survive to catch the real event"
    assert_nil trigger.trigger_conditions.sole.reload.last_triggered_at,
      "the one-shot guard must be unspent — this wake has not happened yet"
  end

  test "four self-wake cycles in a row wake the watcher zero times" do
    trigger = watch(@watched, "session_needs_input")

    4.times do
      @watched.reload.update!(status: :running)
      schedule_self_wake(@watched)
      pause_and_settle(@watched)
      @watched.reload
    end

    assert @watcher.reload.needs_input?
    assert Trigger.exists?(trigger.id)
    assert_nil trigger.trigger_conditions.sole.reload.last_triggered_at
  end

  test "a watched session pausing with a message queued for it does not wake its watcher" do
    trigger = watch(@watched, "session_needs_input")
    @watched.enqueued_messages.create!(content: "follow up", position: 1)

    pause_and_settle(@watched)

    assert @watched.reload.needs_input?, "it did cross into needs_input"
    assert @watcher.reload.needs_input?,
      "but a drain is on its way to resume it, so it is not at rest and nobody should be woken"
    assert Trigger.exists?(trigger.id)
  end

  test "a session that churns past the settle window supersedes the earlier event" do
    trigger = watch(@watched, "session_needs_input")

    job_args = capture_needs_input_job { @watched.pause! }

    # It resumed and paused again inside the window. The second pause emits its
    # own event; the first is about a rest that is no longer the current one.
    @watched.reload.resume!
    @watched.reload.pause!

    AoEventTriggerJob.perform_now(*job_args)

    assert @watcher.reload.needs_input?, "the superseded event must not deliver"
    assert Trigger.exists?(trigger.id)
  end

  # === The signals that must still get through ===

  test "a watched session that genuinely comes to rest DOES wake its watcher" do
    trigger = watch(@watched, "session_needs_input")

    pause_and_settle(@watched)

    assert @watched.reload.needs_input?
    assert_not Trigger.exists?(trigger.id),
      "a delivered one-time wake auto-deletes — this is the wake we wanted"
    assert @watcher.reload.running?, "the watcher was resumed"
  end

  test "the terminal events are not settled and fire on the transition itself" do
    %w[session_failed session_archived].each do |event_name|
      watcher = create_session(status: :needs_input, prompt: "Watcher for #{event_name}")
      watched = create_session(status: :running, is_autonomous: true, prompt: "Watched #{event_name}")
      trigger = watch(watched, event_name, watcher: watcher)

      run_deferred_commit_callbacks_inline
      perform_enqueued_jobs(only: AoEventTriggerJob) do
        event_name == "session_failed" ? watched.fail! : watched.archive!
      end

      assert_not Trigger.exists?(trigger.id), "#{event_name} must still deliver immediately"
      assert watcher.reload.running?, "#{event_name} must still resume the watcher"
    end
  end

  # === archive cleanup of a multi-condition wake ===

  test "archiving a watched session prunes the moot conditions and leaves session_archived to fire" do
    trigger = watch_many(@watched, %w[session_needs_input session_failed session_archived])

    run_deferred_commit_callbacks_inline
    perform_enqueued_jobs(only: AoEventTriggerJob) { @watched.archive! }

    assert_not Trigger.exists?(trigger.id),
      "the session_archived condition fires on this very archival, and the fire destroys the trigger"
    assert @watcher.reload.running?, "the watcher was woken by the archival"
  end

  test "archiving a watched session destroys a multi-condition wake that cannot fire on it" do
    trigger = watch_many(@watched, %w[session_needs_input session_failed])

    run_deferred_commit_callbacks_inline
    perform_enqueued_jobs(only: AoEventTriggerJob) { @watched.archive! }

    assert_not Trigger.exists?(trigger.id),
      "every condition watched a session that will never transition again — the whole trigger is moot"
    assert @watcher.reload.needs_input?, "and nothing woke the watcher, because nothing it asked for happened"
  end

  private

  def watch_many(watched, event_names, watcher: @watcher)
    Trigger.create!(
      name: "Wake ##{watcher.id} on #{event_names.join('/')} of ##{watched.id}",
      agent_root_name: "zimmer",
      prompt_template: "Watched session reached {{event}}",
      reuse_session: true,
      last_session_id: watcher.id,
      trigger_conditions_attributes: event_names.map do |event_name|
        {
          condition_type: "ao_event",
          configuration: { "event_name" => event_name, "watched_session_id" => watched.id }
        }
      end
    ).tap { watcher.update_columns(status: Session.statuses[:needs_input]) }
  end

  def create_session(**attrs)
    Session.create!(
      {
        prompt: "Test",
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo",
        metadata: {}
      }.merge(attrs)
    )
  end

  # One trigger watching one event, in the shape wake_me_up_when_session_changes_state
  # builds. Created directly rather than through the tool so the requester's status
  # is under the test's control.
  def watch(watched, event_name, watcher: @watcher)
    Trigger.create!(
      name: "Wake ##{watcher.id} on #{event_name} of ##{watched.id}",
      agent_root_name: "zimmer",
      prompt_template: "Watched session reached #{event_name}",
      reuse_session: true,
      last_session_id: watcher.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: { "event_name" => event_name, "watched_session_id" => watched.id }
        }
      ]
    ).tap do
      # Trigger creation sleeps a needs_input requester as a side effect. Put it
      # back where the test wants it: what is under test is whether the FIRE
      # resumes it, and `waiting` and `needs_input` are both resumable.
      watcher.update_columns(status: Session.statuses[:needs_input])
    end
  end

  # What `wake_me_up_later` does to a running session: record the intent, so the
  # next pause executes it and the session lands in `waiting`.
  def schedule_self_wake(session)
    session.update!(metadata: (session.metadata || {}).merge("pending_sleep" => true))
  end

  # Pause, then run the wake the pause emitted — after the settle window, which is
  # when the real worker picks it up.
  def pause_and_settle(session)
    args = capture_needs_input_job { session.pause! }
    travel_to SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.from_now do
      AoEventTriggerJob.perform_now(*args)
    end
  end

  # The arguments the pause enqueued, so the test can perform the job at the far
  # side of the settle window instead of immediately.
  def capture_needs_input_job(&block)
    run_deferred_commit_callbacks_inline
    before = enqueued_jobs.size
    block.call
    job = enqueued_jobs[before..].find do |enqueued|
      enqueued[:job] == AoEventTriggerJob && enqueued[:args].first == "session_needs_input"
    end
    assert job, "expected the pause to enqueue a session_needs_input wake"
    ActiveJob::Arguments.deserialize(job[:args])
  end

  def run_deferred_commit_callbacks_inline
    ActiveRecord.stubs(:after_all_transactions_commit).yields
  end
end
