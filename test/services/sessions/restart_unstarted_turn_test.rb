require "test_helper"
require "mocha/minitest"

# The two branches this service exists to tell apart:
#
#   * production session 12267 — its process died before the runtime wrote a line,
#     so there is nothing to resume and the stored prompt is what should run;
#   * production session 12265 — same worker interruption, but it had already made
#     tool calls, so it MUST be resumed rather than restarted from scratch.
class Sessions::RestartUnstartedTurnTest < ActiveJob::TestCase
  setup do
    @clone_path = Dir.mktmpdir("restart_unstarted_turn_test")
    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      transcript: nil,
      metadata: { "clone_path" => @clone_path, "working_directory" => @clone_path, "runtime_started" => true }
    )
  end

  teardown do
    FileUtils.rm_rf(@clone_path) if @clone_path && Dir.exist?(@clone_path)
  end

  def restart
    Sessions::RestartUnstartedTurn.call(@session, working_directory: @clone_path)
  end

  # A conversation record, in the shape TranscriptNormalizer counts as one.
  def conversation_transcript
    { "type" => "user", "message" => { "content" => "Ship the thing" } }.to_json
  end

  test "restarts a session whose runtime never wrote a conversation, carrying its own prompt" do
    result = nil
    assert_enqueued_with(job: AgentSessionJob) do
      result = restart
    end

    assert result.restarted?, "a session with no conversation must be restarted, not parked"

    @session.reload
    assert_equal "running", @session.status
    assert_equal "Ship the thing", @session.metadata["pending_follow_up_prompt"],
      "the restart must carry the session's own prompt, not a generic recovery nudge"
    assert_not_nil @session.running_job_id,
      "a restart that leaves no tracked job is the stall this service is fixing"
    assert_equal 1, @session.metadata[Sessions::RestartUnstartedTurn::BUDGET.key]
  end

  test "the restarted spawn is told to start fresh rather than resume a conversation that does not exist" do
    original_session_id = @session.session_id

    assert restart.restarted?

    @session.reload
    assert_equal false, @session.metadata["runtime_started"],
      "runtime_started must be off so the spawn builds --session-id, not --resume"
    assert_not_equal original_session_id, @session.session_id,
      "a new runtime session id sidesteps the id that is too present to create and too empty to resume (#519)"
    assert_not_nil @session.session_id
  end

  test "declines a session that already has a conversation, so the caller's resume path is untouched" do
    @session.update!(transcript: conversation_transcript)

    result = nil
    assert_no_enqueued_jobs only: AgentSessionJob do
      result = restart
    end

    assert result.declined?, "a mid-conversation session must never be restarted from scratch"
    @session.reload
    assert_equal true, @session.metadata["runtime_started"]
    assert_nil @session.metadata["pending_follow_up_prompt"]
  end

  test "declines when the runtime's own transcript file holds a conversation Zimmer has not polled yet" do
    # Zimmer's copy is empty; the on-disk copy is not. Asking only Zimmer's copy
    # would restart a session that is genuinely mid-turn.
    source = TranscriptRuntime.source_for(@session)
    path = source.resume_transcript_path(session: @session, working_directory: @clone_path)
    skip "runtime does not expose a single resume transcript path" if path.nil?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, conversation_transcript + "\n")

    result = Sessions::RestartUnstartedTurn.call(
      @session, working_directory: @clone_path, file_system: RealFileSystemAdapter.new
    )

    assert result.declined?, "a conversation only the runtime has written still counts as a conversation"
  end

  test "declines a session with no prompt to replay" do
    @session.update!(prompt: nil)

    result = nil
    assert_no_enqueued_jobs only: AgentSessionJob do
      result = restart
    end

    assert result.declined?
  end

  test "replays the follow-up that was in flight rather than the session's first prompt" do
    @session.merge_metadata!("pending_follow_up_prompt" => "Actually, do the other thing")

    assert restart.restarted?

    assert_equal "Actually, do the other thing", @session.reload.metadata["pending_follow_up_prompt"],
      "the lost turn is the one to replay"
  end

  test "gives up once the restart budget is spent rather than respawning forever" do
    @session.merge_metadata!(
      Sessions::RestartUnstartedTurn::BUDGET.key => Sessions::RestartUnstartedTurn::BUDGET.max
    )

    result = nil
    assert_no_enqueued_jobs only: AgentSessionJob do
      result = restart
    end

    assert result.abandoned?, "the cap must stop a genuinely broken session respawning without end"
    assert_match(/never wrote a conversation/, @session.reload.metadata[Sessions::RestartUnstartedTurn::ABANDONED_KEY])
  end

  test "the budget is shared with the in-process empty-turn recovery" do
    assert_same RetryBudget::EMPTY_TURN, Sessions::RestartUnstartedTurn::BUDGET,
      "one event seen from two vantage points must not get two allowances"
    assert_same Sessions::RestartUnstartedTurn::BUDGET, ProcessLifecycleManager::EMPTY_TURN_BUDGET
    assert_equal "empty_turn_recovery_count", Sessions::RestartUnstartedTurn::BUDGET.key
  end

  test "a restart stamps the budget so a stable stretch can hand it back" do
    frozen = Time.utc(2026, 9, 3, 12, 0, 0)

    travel_to(frozen) { restart }

    metadata = @session.reload.metadata
    assert_equal 1, metadata["empty_turn_recovery_count"]
    assert_equal frozen.iso8601, metadata["last_empty_turn_recovery_at"],
      "without the stamp reset_stable_retry_budgets has nothing to measure stability from"
  end

  test "restarts up to the cap and no further" do
    outcomes = (Sessions::RestartUnstartedTurn::BUDGET.max + 1).times.map do
      Sessions::RestartUnstartedTurn.call(@session.reload, working_directory: @clone_path).outcome
    end

    expected = ([ :restarted ] * Sessions::RestartUnstartedTurn::BUDGET.max) + [ :abandoned ]
    assert_equal expected, outcomes
  end

  test "declines rather than raising when the restart cannot be carried out" do
    @session.stubs(:deliver_follow_up!).raises(StandardError, "database is on fire")

    result = Sessions::RestartUnstartedTurn.call(@session, working_directory: @clone_path)

    assert result.declined?, "a recovery that cannot run must fall back to the caller's park, not explode"
    assert_equal "database is on fire", result.message
  end

  test "leaves the runtime session id alone when the restart could not be carried out" do
    original_session_id = @session.session_id
    @session.stubs(:deliver_follow_up!).raises(StandardError, "database is on fire")

    assert Sessions::RestartUnstartedTurn.call(@session, working_directory: @clone_path).declined?

    assert_equal original_session_id, @session.reload.session_id,
      "the caller parks after a declined restart, and must not be left holding an id no spawn took"
  end

  test "drops the stored runtime session id for a runtime that mints its own" do
    @session.update!(agent_runtime: "codex")
    skip "codex runtime not registered" unless TranscriptRuntime.normalizer_for(@session).mints_own_session_id?

    assert restart.restarted?

    assert_nil @session.reload.session_id,
      "leaving it set keeps transcript polling reading the abandoned rollout"
  end

  # The follow-up job reclassifies a session with no `session_id` as a fresh start and
  # spawns carrying `session.prompt`. That is right when `session.prompt` is what we
  # chose to replay, and would silently substitute the first prompt for a lost
  # follow-up otherwise — so on a mints-its-own-id runtime the id survives that case.
  test "keeps the stored runtime session id when a mints-own-id runtime is replaying a follow-up" do
    @session.update!(agent_runtime: "codex")
    skip "codex runtime not registered" unless TranscriptRuntime.normalizer_for(@session).mints_own_session_id?
    @session.merge_metadata!("pending_follow_up_prompt" => "Actually, do the other thing")
    original_session_id = @session.session_id

    assert restart.restarted?

    @session.reload
    assert_equal original_session_id, @session.session_id,
      "replaying the right turn outranks re-attaching the poller a turn earlier"
    assert_equal "Actually, do the other thing", @session.metadata["pending_follow_up_prompt"]
  end

  # `active_follow_up_prompt` holds build_prompt_with_goal OUTPUT, and deliver_follow_up!
  # expands again — so replaying it would hand the agent the goal block twice.
  test "never replays the already-expanded active_follow_up_prompt" do
    @session.merge_metadata!(
      "active_follow_up_prompt" => "Do the thing\n\nThe user has indicated the goal for this task is: Open a PR.",
      "pending_follow_up_prompt" => "Do the thing"
    )

    assert restart.restarted?

    assert_equal "Do the thing", @session.reload.metadata["pending_follow_up_prompt"],
      "the raw text is what gets replayed; the delivery path re-applies the goal itself"
  end
end
