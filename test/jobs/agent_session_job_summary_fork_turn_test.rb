# frozen_string_literal: true

require "test_helper"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"
require "automated_prompts"

# A status-summary fork answers one question and stops.
#
# THE BUG THESE PIN (#695). SessionStatusSummaryGenerator forks a session's
# CONVERSATION into a throwaway fork and asks it, in one follow-up, to write the
# source session's Status panel — so the fork holds a copy of the source's turns.
# Nothing in Zimmer's automated-continuation machinery knew that: the quota-park
# resume, the orphan sweep, the health-monitor retry and the post-interrupt
# auto-continue all deliver a generic "you may have been interrupted, continue
# where you left off" nudge to whatever session they find in a resumable state.
#
# Handed that prompt on top of another session's conversation, the fork continued
# that conversation. On 2026-08-29 (fork #10350 of router #6496) and again on
# 2026-09-03 (fork #13070 of router #13053) a summary fork of a `zimmer-router`
# session re-polled the router's child, registered fresh wake triggers ON ITSELF
# — 14673 and 14674, both still armed when the harvest archived the fork two
# minutes later — and filed a GitHub issue. Two sessions were live for one line
# of work. Because SessionStatusSummaryHarvestJob publishes the LAST assistant
# message after the fork point, the source session's Status panel was then
# overwritten with the fork's routing disposition instead of a summary.
#
# The assertion that matters is `resumed_sessions` / `executed_commands` on the
# CLI adapter: those are the calls that spend a turn.
class AgentSessionJobSummaryForkTurnTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/summary-fork-turn-test-clone"

  setup do
    @source = Session.create!(
      prompt: "Route this issue",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :waiting,
      transcript: { "type" => "user", "message" => { "content" => "Route this issue" } }.to_json
    )
    @fork = Session.create!(
      prompt: "Route this issue",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: {
        "clone_path" => CLONE_PATH,
        "working_directory" => CLONE_PATH,
        "runtime_started" => true,
        "forked_from_session_id" => @source.id,
        "forked_at_message_index" => 0,
        SessionStatusSummaryGenerator::FORK_MARKER => @source.id
      },
      transcript: { "type" => "user", "message" => { "content" => "Route this issue" } }.to_json
    )
  end

  # ---------------------------------------------------------------------------
  # The second turn itself
  # ---------------------------------------------------------------------------

  test "a summary fork handed a system-recovery nudge never reaches the runtime" do
    cli = run_job(@fork, AutomatedPrompts::SYSTEM_RECOVERY)

    assert_empty cli.resumed_sessions,
                 "a nudge must not resume another session's conversation inside a summary fork"
    assert_empty cli.executed_commands, "a summary fork takes one turn, and it already had it"
    assert_nil @fork.reload.metadata["job_started_at"],
               "the turn is refused before the job records itself as started"
  end

  test "the reasoned nudge the post-interrupt auto-continue sends is refused too" do
    # The 2026-08-29 occurrence: auto_continue_after_interrupt's variant, which
    # carries a reason suffix and so is not `==` SYSTEM_RECOVERY.
    cli = run_job(@fork, AutomatedPrompts.system_recovery(
      reason: "the Zimmer job monitoring this session was interrupted before it finished, " \
              "so the session was resumed on a fresh one"
    ))

    assert_empty cli.resumed_sessions
    assert_empty cli.executed_commands
  end

  test "a refused fork comes to rest so its answer is still harvested" do
    assert_enqueued_with(job: SessionStatusSummaryHarvestJob) do
      run_job(@fork, AutomatedPrompts::SYSTEM_RECOVERY)
    end

    @fork.reload
    assert_equal "needs_input", @fork.status, "the fork is brought to rest, not left running"
    assert_nil @fork.running_job_id, "a refused turn leaves no owner on the row"
  end

  test "a fork that already armed a wake and went to sleep is harvested rather than stranded" do
    # `sleep` fires no harvest hook, so this is the one resting state where the
    # refusal has to enqueue the harvest itself — otherwise the fork sleeps
    # forever holding its clone.
    @fork.update!(status: :waiting)

    assert_enqueued_with(job: SessionStatusSummaryHarvestJob) do
      run_job(@fork, AutomatedPrompts::SYSTEM_RECOVERY)
    end
    assert_equal "waiting", @fork.reload.status
  end

  test "the refusal says why on the fork's own timeline" do
    run_job(@fork, AutomatedPrompts::SYSTEM_RECOVERY)

    refusal = @fork.logs.reload.find { |entry| entry.content.include?("status-summary fork") }
    assert_not_nil refusal, "expected a session log explaining why nothing happened"
    assert_equal "info", refusal.level, "a fork declining a second turn is an outcome, not a fault"
    assert_includes refusal.content, "answers one question and stops"
    assert_includes refusal.content, @source.id.to_s, "the timeline should name the session it summarizes"
    assert_includes refusal.content, "The prompt it was carrying was not delivered"
  end

  # ---------------------------------------------------------------------------
  # What must still get through
  # ---------------------------------------------------------------------------

  test "the summary request itself runs — the guard does not break the generation" do
    cli = run_job(@fork, summary_prompt)

    assert_equal 1, cli.resumed_sessions.length, "the fork's one turn must still be delivered"
    assert_includes cli.resumed_sessions.first[:prompt], "Write the Status panel"
  end

  test "a summary request re-delivered from the pending slot runs" do
    # SigtermRetryService and the undelivered-turn path re-enqueue a turn that was
    # never spent by stamping it here, with no prompt on the job's own arguments.
    @fork.merge_metadata!("pending_follow_up_prompt" => summary_prompt)

    cli = run_job(@fork, nil)

    assert_equal 1, cli.resumed_sessions.length,
                 "a summary turn that never ran must still be allowed to run"
  end

  test "a monitoring resume is not refused, so a live fork process still gets cleaned up" do
    @fork.merge_metadata!("process_pid" => 4242)

    job = build_job(MockClaudeCliAdapter.new)
    job.file_system.mkdir_p(CLONE_PATH)
    job.perform(@fork.id, nil, resume_monitoring: true)

    refusal = @fork.logs.reload.find { |entry| entry.content.include?("status-summary fork") }
    assert_nil refusal, "a monitoring resume must get past the guard to do its cleanup"
  end

  test "an ordinary session's recovery nudge is untouched" do
    ordinary = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: { "clone_path" => CLONE_PATH, "working_directory" => CLONE_PATH, "runtime_started" => true },
      transcript: { "type" => "user", "message" => { "content" => "Test prompt" } }.to_json
    )

    cli = run_job(ordinary, AutomatedPrompts::SYSTEM_RECOVERY)

    assert_equal 1, cli.resumed_sessions.length, "only a summary fork is bounded to one turn"
  end

  private

  def summary_prompt
    SessionStatusSummaryGenerator.new(session: @source).send(:prompt_for, @fork)
  end

  # Drive the real job for one turn with the runtime, the filesystem and the
  # process manager mocked out. Mirrors AgentSessionJobSpotGateTest#run_job so the
  # two read the same way.
  def run_job(session, prompt)
    cli = MockClaudeCliAdapter.new
    cli.resume_hook = ->(_opts) { { pid: 12_346, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }
    cli.execute_hook = ->(_opts) { { pid: 12_347, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }

    job = build_job(cli)
    job.file_system.mkdir_p(CLONE_PATH)
    job.file_system.write("#{CLONE_PATH}/claude_stderr.log", "")
    job.process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(0) ] }

    SpotGateService.stub(:evaluate, allowed_decision) do
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
    end

    cli
  end

  def build_job(cli)
    job = AgentSessionJob.new
    job.process_manager = MockProcessManager.new
    job.file_system = MockFileSystemAdapter.new
    job.cli_adapter = cli
    job
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken, and 5-hour has $412.00 of spot budget left.",
      five_hour: nil, weekly: nil, active_sessions: 1, awaiting_sessions: 0, fleet_cap: 10,
      accounts_read: 4, pool_size: 4,
      fleet_burn_usd_per_minute: 0.4, candidate_burn_usd_per_minute: 0.4,
      pool_capacity: nil
    )
  end
end
