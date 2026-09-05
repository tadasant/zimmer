# frozen_string_literal: true

require "test_helper"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# One fault, one answer: a session whose clone is gone is rebuilt, not failed.
#
# THE BUG THESE PIN (#817). "The clone directory is not there" reached two code
# paths in AgentSessionJob and got two different answers. The follow-up path
# recreated the clone from the row and carried on; the `resume_monitoring`
# validator returned "clone directory not found at <path>" and took the session to
# `failed`, which is terminal — `failed` rejects `follow_up`, so a human's only
# option was to hand-respawn the task as a brand-new session, losing the session's
# identity, transcript and place in its hierarchy. Production session 12280 took
# the second path after running for two hours and ten minutes.
#
# Both directions are pinned, because the risk runs both ways. Too permissive and a
# session whose side effects have already been taken resumes and re-does them
# (#716, #801); too strict and a genuine failure is swallowed into a retry loop.
class AgentSessionJobLostCloneRecoveryTest < ActiveJob::TestCase
  LOST_PATH = "/tmp/lost-clone-recovery-test-clone"
  REBUILT_PATH = "/tmp/lost-clone-recovery-test-rebuilt"
  LOST_CLONE_NOTICE = "Zimmer has rebuilt it by re-cloning"

  setup do
    @session = Session.create!(
      prompt: "Implement the thing",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "feature/x",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: {
        "clone_path" => LOST_PATH,
        "working_directory" => LOST_PATH,
        "process_pid" => 4242,
        "runtime_started" => true
      },
      transcript: conversation
    )
  end

  # ---------------------------------------------------------------------------
  # The recovery — a conversation to come back to
  # ---------------------------------------------------------------------------

  test "a resume whose clone is gone rebuilds the tree instead of failing the session" do
    run_resume_with_missing_clone

    @session.reload
    assert_equal "running", @session.status,
                 "the whole point of #817: this used to be a terminal `failed`"
    assert_nil @session.metadata["failure_reason"],
               "nothing failed — the tree is being rebuilt"
    assert_equal 1, RetryBudget::LOST_CLONE.count_for(@session),
                 "the rebuild spends one attempt against its budget"
    assert @session.metadata["last_lost_clone_recovery_at"].present?
  end

  test "the rebuild queues a turn that tells the agent its uncommitted work is gone" do
    assert_enqueued_with(job: AgentSessionJob) { run_resume_with_missing_clone }

    prompt = @session.reload.metadata["pending_follow_up_prompt"]
    assert_includes prompt, LOST_CLONE_NOTICE
    assert_includes prompt, "https://github.com/test/repo.git"
    assert_includes prompt, "feature/x"
    assert_includes prompt, "Any uncommitted work in the old tree is gone"

    refute AutomatedPrompts.system_recovery?(prompt),
           "a bare 'continue where you left off' would invite the agent to carry on against a " \
           "tree that no longer matches a word of its own transcript"
    refute AutomatedPrompts.nudge?(prompt), "it carries its own instruction, so it is not a nudge"
  end

  test "the rebuild keeps the session's identity, transcript and place in its hierarchy" do
    parent = Session.create!(
      prompt: "Parent", agent_runtime: "claude_code", status: :running,
      git_root: "https://github.com/test/repo.git", execution_provider: "local_filesystem"
    )
    @session.update!(parent_session_id: parent.id)
    original_session_id = @session.session_id

    run_resume_with_missing_clone

    @session.reload
    assert_equal original_session_id, @session.session_id,
                 "the runtime session id is what --resume reads; a re-spawn is what loses it"
    assert_equal conversation, @session.transcript
    assert_equal parent.id, @session.parent_session_id
  end

  test "the rebuild says on the session's own timeline what it is doing and what is lost" do
    run_resume_with_missing_clone

    log = @session.logs.reload.find { |entry| entry.content.include?("rebuilding the working tree") }
    assert_not_nil log, "a reader asking why this session restarted needs the answer here"
    assert_includes log.content, LOST_PATH
    assert_includes log.content, "https://github.com/test/repo.git"
    assert_includes log.content, "Uncommitted work in the lost tree cannot be recovered."
    assert_equal "warning", log.level
  end

  # The end-to-end half: the turn the recovery queued is actually run, and the clone
  # really is rebuilt under it. Without this the recovery is only a promise.
  test "the queued turn rebuilds the clone and resumes the conversation in it" do
    run_resume_with_missing_clone

    follow_up = enqueued_jobs.find { |job| job[:job] == AgentSessionJob }
    assert_not_nil follow_up, "the recovery must have queued the turn that does the rebuilding"

    job = build_job
    # The turn the recovery queued, run under the job id the session is holding for it.
    # A different id is what the concurrency guard exists to refuse.
    job.job_id = follow_up[:job_id]
    job.file_system.mkdir_p(REBUILT_PATH)
    job.file_system.write("#{REBUILT_PATH}/claude_stderr.log", "")
    job.process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(0) ] }

    clone_requests = []
    GitCloneService.stub(:create_clone, ->(git_root, **kwargs) {
      clone_requests << { git_root: git_root }.merge(kwargs)
      job.file_system.mkdir_p(REBUILT_PATH)
      { clone_path: REBUILT_PATH, working_directory: REBUILT_PATH }
    }) do
      run_job_without_polling(job) do
        job.perform(@session.id, @session.reload.metadata["pending_follow_up_prompt"])
      end
    end

    assert_equal 1, clone_requests.size, "the tree is rebuilt exactly once"
    assert_equal "https://github.com/test/repo.git", clone_requests.first[:git_root]
    assert_equal "feature/x", clone_requests.first[:branch],
                 "rebuilt from the branch the row records, not from the default"

    @session.reload
    assert_equal true, @session.metadata["clone_recreated"]
    assert_equal REBUILT_PATH, @session.metadata["clone_path"]
    assert_equal REBUILT_PATH, @session.metadata["working_directory"]

    resumed = job.cli_adapter.resumed_sessions
    assert_equal 1, resumed.size, "the conversation is resumed, not started over"
    assert_equal @session.session_id, resumed.first[:session_id]
    assert_equal REBUILT_PATH, resumed.first[:working_dir]
    assert_includes resumed.first[:prompt], LOST_CLONE_NOTICE

    # The runtime resumes from the clone's own <session_id>.jsonl, not from
    # session.transcript — so a rebuilt tree with no transcript file in it resumes an
    # empty conversation and silently drops the turn. It has to be re-materialized.
    restored = job.file_system.read(
      TranscriptRuntime.source_for(@session, file_system: job.file_system)
        .resume_transcript_path(session: @session, working_directory: REBUILT_PATH)
    )
    assert_equal conversation, restored,
                 "the stored transcript must be written into the rebuilt clone before the resume"
  end

  # ---------------------------------------------------------------------------
  # The boundaries — failures that must stay terminal
  # ---------------------------------------------------------------------------

  test "a clone that keeps vanishing fails once the rebuild budget is spent" do
    @session.merge_metadata!(RetryBudget::LOST_CLONE.key => RetryBudget::LOST_CLONE.max)

    run_resume_with_missing_clone

    @session.reload
    assert_equal "failed", @session.status, "a tree that will not stay on disk is not a retry loop"
    assert_equal "clone directory not found at #{LOST_PATH}", @session.metadata["failure_reason"]
    assert_includes @session.metadata[Sessions::RecoverLostClone::ABANDONED_KEY].to_s,
                    "gone missing again"
    assert_no_enqueued_jobs only: AgentSessionJob
  end

  test "a live process at the recorded pid is left alone rather than raced" do
    run_resume_with_missing_clone { |job| job.process_manager.set_process_state(4242, :running) }

    @session.reload
    assert_equal "failed", @session.status,
                 "something is still driving this session; a rebuild would put a second agent on it"
    assert_includes all_log_content, "is still running"
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session)
  end

  # `refuse_archived_session` is skipped for resume_monitoring jobs and `resume`
  # transitions out of `failed`, so a status check is the recovery's own job.
  test "an archived session is not handed a turn it cannot take" do
    @session.archive!

    run_resume_with_missing_clone

    @session.reload
    assert_equal "archived", @session.status
    assert_nil @session.metadata["pending_follow_up_prompt"],
               "a stamped prompt would survive to whatever delivers the next turn if this session " \
               "is ever unarchived"
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session)
    assert_includes all_log_content, "the session is archived"
  end

  test "a session that already reached failed is not resurrected into a real turn" do
    @session.fail!

    run_resume_with_missing_clone

    @session.reload
    assert_equal "failed", @session.status,
                 "`resume` accepts `failed`, so nothing but this check stops a terminal session " \
                 "taking an agent turn with side effects"
    assert_nil @session.metadata["pending_follow_up_prompt"]
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session)
  end

  test "a validation failure that is not about the clone is untouched" do
    @session.update_column(:session_id, "not-a-uuid")

    run_resume_with_missing_clone

    @session.reload
    assert_equal "failed", @session.status
    assert_equal "session_id is not a valid UUID format", @session.metadata["failure_reason"],
                 "only the missing clone has a rebuild; every other fault is a fact a rebuild " \
                 "would not change"
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session)
  end

  test "a clone that is present but unreadable is not rebuilt over" do
    unreadable = MockFileSystemAdapter.new
    unreadable.mkdir_p(LOST_PATH)
    def unreadable.readable?(_path) = false

    run_resume_with_missing_clone(file_system: unreadable)

    @session.reload
    assert_equal "failed", @session.status
    assert_equal "clone directory not accessible at #{LOST_PATH}", @session.metadata["failure_reason"],
                 "there is a tree at that path; `git clone` would refuse it and a rebuild is not " \
                 "the answer to a permissions problem"
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session)
  end

  # ---------------------------------------------------------------------------
  # No conversation — the other service owns it
  # ---------------------------------------------------------------------------

  # A session that never reached needs_input, in its sharpest form: the runtime was
  # spawned and wrote nothing. There is no conversation to resume into, so the
  # lost-clone notice would be delivered into an empty context. Sessions::
  # RestartUnstartedTurn already owns exactly this shape and replays the session's own
  # prompt — nothing was consumed, so nothing is re-done.
  test "a session that never wrote a conversation replays its own prompt instead" do
    @session.update!(transcript: nil)

    run_resume_with_missing_clone

    @session.reload
    assert_equal "running", @session.status
    assert_equal "Implement the thing", @session.metadata["pending_follow_up_prompt"],
                 "with nothing written there is nothing to carry on from, so the task itself runs"
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session),
                 "the unstarted-turn budget bounds this one, not the lost-clone budget"
    assert_equal 1, RetryBudget::EMPTY_TURN.count_for(@session)
  end

  # The give-up is `needs_input`, which is what RetryBudget::EMPTY_TURN declares as its
  # terminal status and what the dead-pid branch does with the same exhaustion. It is
  # also the only one of the two resting states that accepts the follow-up that would
  # rebuild the clone, so `failed` here would be the very trap #817 is about.
  test "a session that never wrote a conversation comes to rest once its own budget is spent" do
    @session.update!(transcript: nil)
    @session.merge_metadata!(RetryBudget::EMPTY_TURN.key => RetryBudget::EMPTY_TURN.max)

    run_resume_with_missing_clone

    @session.reload
    assert_equal "needs_input", @session.status
    assert_equal "unstarted_turn_not_recoverable", @session.metadata["failure_reason"]
    assert_includes @session.metadata[Sessions::RestartUnstartedTurn::ABANDONED_KEY].to_s,
                    "never wrote a conversation"
    assert_nil @session.metadata["paused_by"],
               "no recovery marker: no sweep can do anything a third restart would not"
    assert_nil @session.running_job_id
  end

  # The hole a stored-transcript-only check would leave, and the case that most
  # deserves the rebuild: the poller was lagging, so Zimmer's copy is blank — but the
  # runtime wrote a full conversation, to a file that lives outside the clone and
  # therefore outlived it.
  test "a lagging poller over a real runtime transcript is still recovered" do
    @session.update!(transcript: nil)

    file_system = MockFileSystemAdapter.new
    runtime_path = TranscriptRuntime.source_for(@session, file_system: file_system)
      .resume_transcript_path(session: @session, working_directory: LOST_PATH)
    file_system.mkdir_p(File.dirname(runtime_path))
    file_system.write(runtime_path, conversation)

    run_resume_with_missing_clone(file_system: file_system)

    @session.reload
    assert_equal "running", @session.status
    assert_includes @session.metadata["pending_follow_up_prompt"].to_s, LOST_CLONE_NOTICE,
                    "the conversation is real, so it is resumed rather than replayed from the prompt"
    assert_equal 1, RetryBudget::LOST_CLONE.count_for(@session)
    assert_equal 0, RetryBudget::EMPTY_TURN.count_for(@session)
  end

  test "the timeline says the clone was missing even when the unstarted-turn path takes it" do
    @session.update!(transcript: nil)

    run_resume_with_missing_clone

    assert_includes all_log_content, "The clone at #{LOST_PATH} is not on disk",
                    "the missing clone is the diagnostic #817 is about; the restart's own log line " \
                    "never mentions it"
  end

  private

  def conversation
    @conversation ||= [
      { "type" => "user", "message" => { "content" => "Implement the thing" } },
      { "type" => "assistant", "message" => { "content" => "Working on it" } }
    ].map(&:to_json).join("\n")
  end

  def build_job(file_system: nil)
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = file_system || MockFileSystemAdapter.new
    job.cli_adapter = MockClaudeCliAdapter.new
    job
  end

  # Drive the real resume-monitoring path with the clone missing from disk — the
  # exact shape of the observed incident.
  def run_resume_with_missing_clone(file_system: nil)
    job = build_job(file_system: file_system)
    yield job if block_given?
    job.perform(@session.id, nil, resume_monitoring: true)
    job
  end

  # The follow-up turn runs the whole spawn/monitor path; stub out the polling thread
  # and the poller so it completes against the mocks rather than sleeping on real IO.
  def run_job_without_polling(_job)
    TranscriptPollerService.stub(:new, ->(_session, file_system: nil, broadcast_service: nil) {
      poller = Object.new
      def poller.poll_and_broadcast; end
      poller
    }) do
      Thread.stub(:new, ->(&_block) {
        thread = Object.new
        def thread.alive? = false
        def thread.kill; end
        def thread.join(*) = nil
        thread
      }) do
        yield
      end
    end
  end

  def all_log_content
    @session.logs.reload.map(&:content).join("\n")
  end
end
