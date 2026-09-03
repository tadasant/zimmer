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

  test "a watched session whose queued message drains does not wake its watcher" do
    trigger = watch(@watched, "session_needs_input")
    @watched.enqueued_messages.create!(content: "follow up", position: 1)

    args = capture_needs_input_job { @watched.pause! }

    # EnqueuedMessageDrainJob's DELAY is well inside the settle window, so by the
    # time the wake is evaluated the session is going again. That is what makes
    # this a boundary rather than a rest — not the presence of the message.
    @watched.reload.resume!

    travel_to SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.from_now do
      AoEventTriggerJob.perform_now(*args)
    end

    assert @watcher.reload.needs_input?, "the drain resumed it, so nobody should have been woken"
    assert Trigger.exists?(trigger.id)
  end

  test "a queued message that never drains still wakes the watcher — a stuck rest is a rest" do
    trigger = watch(@watched, "session_needs_input")
    @watched.enqueued_messages.create!(content: "follow up", position: 1)

    # EnqueuedMessageDrainJob gives up after MAX_ATTEMPTS and deliberately leaves
    # the rows pending on an idle session; three `skip_reason` refusals hold a
    # message indefinitely too. `pause` only fires from `running`, so nothing
    # re-emits this event — suppressing here would lose the wake for good rather
    # than delay it, and the session really is sitting at rest.
    pause_and_settle(@watched)

    assert @watched.reload.needs_input?
    assert_not Trigger.exists?(trigger.id), "the wake must be delivered, not dropped"
    assert @watcher.reload.running?
  end

  test "a session left holding an unexecuted pending_sleep still wakes its watcher" do
    trigger = watch(@watched, "session_needs_input")

    # execute_pending_sleep's rescue: `sleep!` raised, the flag survives, and its
    # own comment says the session "sits in needs_input on the user's homepage as
    # if it wanted attention". A watcher of that session must be told.
    @watched.stubs(:sleep!).raises(StandardError, "sleep failed")
    schedule_self_wake(@watched)
    pause_and_settle(@watched)

    assert @watched.reload.needs_input?
    assert_equal true, @watched.metadata["pending_sleep"]
    assert_not Trigger.exists?(trigger.id), "the wake must be delivered, not dropped"
    assert @watcher.reload.running?
  end

  test "an elicitation the user answers inside the window does not wake the watcher" do
    trigger = watch(@watched, "session_needs_input")

    # Creating the elicitation is what drives block_on_elicitation! — the session
    # syncs its own state off it (Elicitation#sync_session_elicitation_state).
    args = capture_needs_input_job { create_blocking_elicitation(@watched) }
    assert @watched.reload.needs_input?

    # Answered in seconds. Resolving the elicitation syncs the session back to
    # `running` on its own, which is the unblock_from_elicitation transition.
    @watched.elicitations.each { |e| e.update!(status: "accept") }
    assert @watched.reload.running?

    travel_to SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.from_now do
      AoEventTriggerJob.perform_now(*args)
    end

    assert @watcher.reload.needs_input?, "a round-trip that resolved is a flap, not a rest"
    assert Trigger.exists?(trigger.id)
  end

  test "an elicitation still waiting on a human DOES wake the watcher" do
    trigger = watch(@watched, "session_needs_input")

    pause_and_settle_on(@watched) { create_blocking_elicitation(@watched) }

    assert_not Trigger.exists?(trigger.id), "the child is asking a human something — that is a real rest"
    assert @watcher.reload.running?
  end

  test "a session deleted before the window closes is stale, not a fire" do
    trigger = watch(@watched, "session_needs_input")

    args = capture_needs_input_job { @watched.pause! }
    watched_id = @watched.id
    @watched.destroy!

    travel_to SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.from_now do
      assert_nothing_raised { AoEventTriggerJob.perform_now(*args) }
    end

    assert_nil Session.find_by(id: watched_id)
    assert @watcher.reload.needs_input?, "there is no subject left for the event to be about"
    assert Trigger.exists?(trigger.id)
  end

  # === the immediate-fire path shares the same rest check ===

  test "registering a watcher on a session already resting in needs_input fires at once" do
    @watched.update!(status: :needs_input)

    run_deferred_commit_callbacks_inline
    trigger = nil
    perform_enqueued_jobs(only: AoEventTriggerJob) do
      trigger = watch(@watched, "session_needs_input", reset_watcher: false)
    end

    assert_not Trigger.exists?(trigger.id), "Trigger#fire_ao_event_immediately_if_state_matches delivered it"
    assert @watcher.reload.running?
  end

  test "the immediate-fire path is subject to the same check and drops a session that has moved on" do
    @watched.update!(status: :needs_input)

    run_deferred_commit_callbacks_inline
    args = nil
    trigger = nil
    before = enqueued_jobs.size
    trigger = watch(@watched, "session_needs_input")
    job = enqueued_jobs[before..].find { |e| e[:job] == AoEventTriggerJob }
    assert job, "expected the immediate-fire path to enqueue a wake"
    args = ActiveJob::Arguments.deserialize(job[:args])

    # It got going again between the enqueue and the job running.
    @watched.reload.resume!
    AoEventTriggerJob.perform_now(*args)

    assert Trigger.exists?(trigger.id), "the watched session is no longer at rest"
    assert @watcher.reload.needs_input?
  end

  # === a recovery pause is not a rest, whichever door the wake comes through ===
  #
  # The pause callback withholds the wake for a recovery pause (#328/#664). The
  # immediate-fire path is the second door into the same wake: a watcher armed
  # while the session is still sitting in that pause used to be fired at once on a
  # status-only test, delivering exactly the wake the transition declined. These
  # pin both halves of the argument — the suppression, and the fact that it is a
  # deferral rather than a deletion.

  test "arming a watcher on a session in a recovery pause does not fire immediately" do
    @watched.update!(status: :needs_input, metadata: { "paused_by" => "recovery" })

    run_deferred_commit_callbacks_inline
    trigger = nil
    assert_no_enqueued_jobs(only: AoEventTriggerJob) do
      # reset_watcher: false so the watcher is left where trigger creation put it,
      # which is what the last assertion below is about.
      trigger = watch(@watched, "session_needs_input", reset_watcher: false)
    end

    assert Trigger.exists?(trigger.id), "the watcher must stay armed for the real event"
    assert_nil trigger.trigger_conditions.sole.reload.last_triggered_at,
      "the one-shot guard must be unspent — this wake has not happened yet"
    assert @watcher.reload.waiting?,
      "the watcher went to sleep on its wake and nothing resumed it"
  end

  test "the suppressed watcher is woken by the sweep it was deferred to giving up" do
    # No session_id, so every sweep fails validation and spends an attempt. This is
    # the strand this suppression could have caused: the watcher was armed inside
    # the pause window and nothing else will ever re-emit the event for it.
    @watched.update!(
      status: :needs_input,
      running_job_id: nil,
      session_id: nil,
      metadata: { "paused_by" => "recovery" }
    )

    run_deferred_commit_callbacks_inline
    before = enqueued_jobs.size
    trigger = watch(@watched, "session_needs_input")
    assert_empty needs_input_wakes_for(@watched, since: before),
      "arming inside the pause window must not fire — that is the door this closes"

    (SessionContinuation::MAX_CONTINUE_ATTEMPTS - 1).times { CleanupOrphanedSessionsJob.perform_now }
    assert_empty needs_input_wakes_for(@watched, since: before),
      "a recovery-paused session with budget left stays silent"

    # The pass that spends the budget drops the marker and makes the announcement
    # the pause skipped, via Session#announce_deferred_needs_input!.
    CleanupOrphanedSessionsJob.perform_now
    wakes = needs_input_wakes_for(@watched, since: before)
    assert_equal 1, wakes.size, "giving up must wake the watcher the recovery pause did not"

    travel_to SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.from_now do
      AoEventTriggerJob.perform_now(*wakes.first)
    end

    assert_not Trigger.exists?(trigger.id), "the armed wake was delivered, not stranded"
    assert @watcher.reload.running?, "the watcher was resumed once the child became a human's problem"
  end

  test "arming a watcher on a recovery pause in a frozen category fires at once" do
    # Nothing sweeps a frozen category (Session.not_in_frozen_category), so there is
    # no give-up branch coming to make the announcement later. Suppressing here
    # would delete the wake rather than defer it — the predicate excludes this case,
    # and the immediate fire has to happen for the same reason the pause announces.
    @watched.update!(
      status: :needs_input,
      category: Category.create!(name: "Parked", is_frozen: true),
      metadata: { "paused_by" => "recovery" }
    )

    run_deferred_commit_callbacks_inline
    trigger = nil
    perform_enqueued_jobs(only: AoEventTriggerJob) do
      trigger = watch(@watched, "session_needs_input", reset_watcher: false)
    end

    assert_not Trigger.exists?(trigger.id), "no sweep is coming — this wake is owed now"
    assert @watcher.reload.running?
  end

  test "arming a watcher on a session a human paused still fires immediately" do
    # The check reads `paused_by == "recovery"` exactly. A human holding the session
    # is a real stop with no auto-continue behind it, and a watcher wants to know.
    @watched.update!(status: :needs_input, metadata: { "paused_by" => "user" })

    run_deferred_commit_callbacks_inline
    trigger = nil
    perform_enqueued_jobs(only: AoEventTriggerJob) do
      trigger = watch(@watched, "session_needs_input", reset_watcher: false)
    end

    assert_not Trigger.exists?(trigger.id)
    assert @watcher.reload.running?
  end

  test "a session_failed watcher fires immediately even on a session carrying the recovery marker" do
    # CleanupOrphanedSessionsJob sweeps `failed` sessions with paused_by "recovery"
    # too, so the marker really can be present here. `session_failed` announced
    # itself unconditionally at its own transition and has no deferral behind it —
    # gating it on this predicate would strand a watcher for a real failure.
    @watched.update!(status: :failed, metadata: { "paused_by" => "recovery" })

    run_deferred_commit_callbacks_inline
    trigger = nil
    perform_enqueued_jobs(only: AoEventTriggerJob) do
      trigger = watch(@watched, "session_failed", reset_watcher: false)
    end

    assert_not Trigger.exists?(trigger.id)
    assert @watcher.reload.running?
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
  # `reset_watcher: false` for the immediate-fire tests: `perform_enqueued_jobs`
  # runs the wake inline as it is enqueued, i.e. inside Trigger.create!, so the
  # status reset below would land AFTER the fire and clobber the resume it is
  # supposed to be observing.
  def watch(watched, event_name, watcher: @watcher, reset_watcher: true)
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
      watcher.update_columns(status: Session.statuses[:needs_input]) if reset_watcher
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
    pause_and_settle_on(session) { session.pause! }
  end

  # The same, for a transition other than `pause` that emits the settled event.
  def pause_and_settle_on(_session, &block)
    args = capture_needs_input_job(&block)
    travel_to SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.from_now do
      AoEventTriggerJob.perform_now(*args)
    end
  end

  def create_blocking_elicitation(session)
    Elicitation.create!(
      session: session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Approve?",
      requested_schema: { "type" => "object" },
      meta: {},
      expires_at: 1.hour.from_now
    )
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

  # The settled session_needs_input wakes enqueued for `session` after position
  # `since` in the queue, deserialized ready to perform.
  def needs_input_wakes_for(session, since:)
    enqueued_jobs[since..].to_a.filter_map do |enqueued|
      next unless enqueued[:job] == AoEventTriggerJob

      args = ActiveJob::Arguments.deserialize(enqueued[:args])
      args if args.first == "session_needs_input" && args[1] == session.id
    end
  end

  def run_deferred_commit_callbacks_inline
    ActiveRecord.stubs(:after_all_transactions_commit).yields
  end
end
