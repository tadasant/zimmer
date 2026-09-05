# frozen_string_literal: true

require "test_helper"
require "automated_prompts"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# A queued message outranks an injected recovery nudge (#566).
#
# THE BUG THESE PIN. Every automated resume in Zimmer ends the same way —
# `AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)`
# — and that turn used to be spent on the nudge whatever was already queued for
# the session. Session 7681 was killed and auto-continued four times in ninety
# minutes on 2026-08-23; a message queued at 13:48Z was still `pending` at
# position 1 at 15:19Z, having lost to the nudge on every cycle, while
# `broadcast_message_count` went 136 -> 284 -> 533. Session 6377's PR-merged
# notice lost the same way after waiting five hours, and was archived over.
#
# The nudge is the one prompt with nothing to add: "you may have been
# interrupted, carry on". Delivering the queued message IS carrying on.
class AgentSessionJobQueuedMessageOverNudgeTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/queued-over-nudge-clone"

  setup do
    @session = Session.create!(
      prompt: "Open a PR and hold it",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: { "clone_path" => CLONE_PATH, "working_directory" => CLONE_PATH, "runtime_started" => true },
      transcript: { "type" => "user", "message" => { "content" => "Open a PR and hold it" } }.to_json
    )
  end

  # ---------------------------------------------------------------------------
  # The window the issue is about
  # ---------------------------------------------------------------------------

  test "a nudge turn is handed to the message already queued for the session" do
    message = queue("Your PR https://github.com/test/repo/pull/7 merged. That is your signal to archive.")

    cli = run_job(@session, nudge)

    assert_empty cli.resumed_sessions,
                 "the nudge must not reach the runtime while a queued message is waiting"
    assert_not EnqueuedMessage.exists?(message.id), "the queued message is claimed and delivered"
    assert_empty @session.enqueued_messages.pending

    handoff = enqueued_jobs.select { |job| job["job_class"] == "AgentSessionJob" }.last
    assert_not_nil handoff, "delivering the message enqueues the turn that carries it"
    assert_equal message.content, (handoff["args"] || handoff[:args])[1],
                 "the turn that replaces the nudge carries the queued message, not the nudge"
  end

  test "the nudge's own delivery marker is dropped so it cannot be re-delivered in place of the message" do
    # `pending_follow_up_prompt` is what a resume stamps for a job that has not
    # picked its prompt up yet, and the follow-up arm reads it in PREFERENCE to
    # the prompt it was handed. Left behind, the job the handoff enqueues would
    # find the nudge sitting there and deliver that instead of the message that
    # just won the turn.
    queue("the actual work")
    @session.merge_metadata!(
      "pending_follow_up_prompt" => nudge,
      "pending_follow_up_sent_at" => Time.current.utc.iso8601
    )

    run_job(@session, nudge)

    @session.reload
    assert_nil @session.metadata["pending_follow_up_prompt"]
    assert_nil @session.metadata["pending_follow_up_sent_at"]
  end

  test "the handoff is legible in the session's own log" do
    queue("the actual work")

    run_job(@session, nudge)

    assert @session.logs.where("content LIKE ?", "%instead of the automated recovery nudge%").exists?,
           "a turn that changed hands must say so where a human reads the session"
  end

  test "a nudge carrying a reason is still a nudge" do
    # Every real caller names itself — AutomatedPrompts.system_recovery(reason:)
    # appends a sentence, so an equality check on the constant would match none
    # of them.
    message = queue("the actual work")
    reasoned = AutomatedPrompts.system_recovery(
      reason: "the Zimmer job monitoring this session was interrupted before it finished, " \
              "so the session was resumed on a fresh one"
    )

    cli = run_job(@session, reasoned)

    assert_empty cli.resumed_sessions
    assert_not EnqueuedMessage.exists?(message.id)
  end

  test "only the front message is taken; the rest ride the turn it starts" do
    first = queue("first", position: 1)
    second = queue("second", position: 2)

    run_job(@session, nudge)

    assert_not EnqueuedMessage.exists?(first.id)
    assert_equal [ "second" ], @session.enqueued_messages.pending.ordered.pluck(:content)
    assert_equal 1, second.reload.position, "the queue renumbers behind the delivered message"
  end

  # ---------------------------------------------------------------------------
  # What must NOT be preempted
  # ---------------------------------------------------------------------------

  test "a human follow-up is delivered as sent, with the queue left behind it" do
    # The queue is not a priority lane. Somebody typing into a session is saying
    # something specific and newer, so it takes the turn and the queue drains
    # behind it through the ordinary end-of-turn path.
    queue("queued earlier")

    cli = run_job(@session, "Actually, use the other branch")

    assert_equal 1, cli.resumed_sessions.length
    assert_includes cli.resumed_sessions.first[:prompt], "Actually, use the other branch"
    refute_includes cli.resumed_sessions.first[:prompt], "queued earlier",
                    "a queued message must not displace a prompt a human just sent"
  end

  test "a nudge is delivered normally when nothing is queued" do
    cli = run_job(@session, nudge)

    assert_equal 1, cli.resumed_sessions.length, "with an empty queue the nudge is the turn"
    assert_includes cli.resumed_sessions.first[:prompt], AutomatedPrompts::SYSTEM_RECOVERY
  end

  # THE ONE THAT LOSES THE MESSAGE. Releasing `running_job_id` is something only
  # the processor's handoff branch does, and that branch is selected by the
  # session already being `running`. From `needs_input` the processor resumes
  # instead, leaving `running_job_id` pointing at the job that is standing down —
  # so the fresh AgentSessionJob would be refused by #perform's concurrency guard
  # and the message would be gone from the queue with no turn behind it.
  test "a session that is not running is left to the ordinary follow-up path" do
    @session.update!(status: :needs_input, running_job_id: SecureRandom.uuid)
    queue("must not be claimed by a job that is standing down")

    cli = run_job(@session, nudge)

    assert_equal 1, cli.resumed_sessions.length, "the nudge is delivered instead, as before"
    assert_includes cli.resumed_sessions.first[:prompt], AutomatedPrompts::SYSTEM_RECOVERY
    refute @session.logs.where("content LIKE ?", "%instead of the automated recovery nudge%").exists?,
           "the turn must not be handed over when the handoff cannot release the job lock"
  end

  # A `running` session's may_resume? is false, so the processor performs no
  # resume — and cancel_pending_one_time_wake_triggers, which a resume would fire,
  # never runs. The wakes a SYSTEM_RECOVERY resume deliberately preserves survive
  # the handoff exactly as they survive the nudge.
  test "the handoff preserves the armed wakes a recovery resume would have kept" do
    Session.any_instance.expects(:cancel_pending_one_time_wake_triggers).never
    queue("the actual work")

    run_job(@session, nudge)

    assert_empty @session.enqueued_messages.pending, "the message still took the turn"
  end

  # A session parked on a quota or auth wall would spend the message on a turn
  # that hits the same wall and parks again — the refusal EnqueuedMessageDrainJob
  # and both end-of-turn handoff sites already make.
  test "a session parked on an auth outage keeps its queued message" do
    @session.merge_metadata!("auth_outage_reason" => "quota_exhausted")
    message = queue("do not burn me on the wall")

    run_job(@session, nudge)

    assert_equal "pending", message.reload.status
  end

  # The gate reads this job's ARGUMENT, but the follow-up arm resolves the prompt
  # as `pending_follow_up_prompt || follow_up_prompt`. A human prompt stamped
  # after this job was enqueued is what would actually be delivered, and taking
  # the turn from it would contradict "scoped to the nudge on purpose".
  test "a human prompt stamped for this turn is not preempted by the queue" do
    queue("queued earlier")
    @session.merge_metadata!("pending_follow_up_prompt" => "Actually, use the other branch")

    cli = run_job(@session, nudge)

    assert_equal 1, cli.resumed_sessions.length
    assert_includes cli.resumed_sessions.first[:prompt], "Actually, use the other branch"
  end

  test "a session that never established a runtime session id is left to the fresh-start path" do
    # A follow-up prompt into a session with no session_id is reclassified as a
    # FRESH START, which spawns on the session's OWN prompt and discards the
    # follow-up. Handing the queued message over at that point would spend it on
    # a turn that throws it away, so the handoff declines and the message drains
    # through the ordinary end-of-turn path instead.
    @session.update!(session_id: nil, status: :waiting, transcript: nil)
    queue("must not be spent on the fresh start")

    cli = run_job(@session, nudge)

    assert_predicate cli.executed_commands, :any?, "a session with no session_id spawns fresh"
    spawned = cli.executed_commands.map { |command| command[:prompt].to_s }
    assert spawned.any? { |prompt| prompt.include?("Open a PR and hold it") },
           "the fresh start runs the session's own prompt"
    refute spawned.any? { |prompt| prompt.include?("must not be spent on the fresh start") },
           "the queued message must not be spent on a turn that would discard it"
  end

  private

  def nudge = AutomatedPrompts::SYSTEM_RECOVERY

  def queue(content, position: nil)
    position ||= (@session.enqueued_messages.maximum(:position) || 0) + 1
    @session.enqueued_messages.create!(content: content, position: position, status: "pending")
  end

  # Drive the real job for one turn with the runtime, the filesystem and the
  # process manager mocked out. `resumed_sessions` is the assertion that matters:
  # it is the call that spends a turn on the runtime.
  def run_job(session, prompt)
    cli = MockClaudeCliAdapter.new
    cli.resume_hook = ->(_opts) { { pid: 12_346, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }
    cli.execute_hook = ->(_opts) { { pid: 12_347, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }

    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = cli
    job.file_system.mkdir_p(CLONE_PATH)
    job.file_system.write("#{CLONE_PATH}/claude_stderr.log", "")
    job.process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(0) ] }

    GitCloneService.stub(:create_clone, { clone_path: CLONE_PATH, working_directory: CLONE_PATH }) do
      TranscriptPollerService.stub(:new, ->(_session, file_system: nil, broadcast_service: nil) {
        poller = Object.new
        def poller.poll_and_broadcast; end
        poller
      }) do
        Thread.stub(:new, ->(&_block) {
          thread = Object.new
          def thread.alive? = false
          def thread.kill; end
          def thread.join(*); end
          thread
        }) do
          job.perform(session.id, prompt)
        end
      end
    end

    cli
  end
end
