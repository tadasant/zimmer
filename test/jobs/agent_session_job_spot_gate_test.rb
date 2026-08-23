# frozen_string_literal: true

require "test_helper"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"

# The spot gate as a choke point on TURNS, not on first starts.
#
# THE BUG THESE PIN. The gate used to read `follow_up_prompt.blank?`, so only a
# session's very first start was gated. Every other shape of turn — a fired
# `wake_me_up_later` backstop, a queued follow-up, a poller-delivered comment, a
# restart — arrives as a follow-up-shaped resume and went straight through. On
# 2026-08-22 session 7504, a spot session, woke on its own backstop trigger and
# ran a full turn at 17:30Z while the gate was reporting HELD at 87% of a 65%
# 5-hour target, force-pausing 22 running spot sessions and holding 141 more at
# the starting line.
#
# Every test here drives the real AgentSessionJob, and the assertion that matters
# is `resumed_sessions` / `executed_commands` on the CLI adapter: those are the
# calls that spend Claude quota. "Deferred" means the runtime was never invoked.
class AgentSessionJobSpotGateTest < ActiveJob::TestCase
  CLONE_PATH = "/tmp/spot-gate-test-clone"

  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      scheduling_class: SessionGenesis::SPOT,
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: { "clone_path" => CLONE_PATH, "working_directory" => CLONE_PATH, "runtime_started" => true },
      transcript: { "type" => "user", "message" => { "content" => "Test prompt" } }.to_json
    )
  end

  # ---------------------------------------------------------------------------
  # The bypass itself
  # ---------------------------------------------------------------------------

  test "a spot session's follow-up turn is deferred while the gate is held" do
    cli = run_job_with_held_gate(@session, "Backstop wake (round 2). Re-poll child #7507...")

    assert_empty cli.resumed_sessions, "a held spot session must not reach the runtime"
    assert_empty cli.executed_commands, "a held spot session must not reach the runtime"

    @session.reload
    assert_nil @session.metadata["job_started_at"],
               "the turn must be refused before the job records itself as started"
    assert_equal "waiting", @session.status,
                 "a deferred session goes back to the spot queue, not the human action queue"
    assert_equal "at_utilization_limit", @session.metadata[SpotSessionHold::HELD_REASON]
    assert_equal SpotSessionHold::TURN_RESUME, @session.metadata[SpotSessionHold::HELD_TURN]
    assert_nil @session.running_job_id, "a deferred session owns no job"
  end

  test "the deferred prompt, its images and its files are re-enqueued intact" do
    images = [ { "path" => "/tmp/shot.png", "media_type" => "image/png" } ]
    files = [ { "path" => "/tmp/log.txt", "original_filename" => "log.txt", "size" => 12 } ]

    assert_enqueued_with(job: AgentSessionJob) do
      run_job_with_held_gate(@session, "Please continue", images: images, files: files)
    end

    enqueued = enqueued_jobs.last
    args = enqueued["args"] || enqueued[:args]
    assert_equal @session.id, args[0]
    assert_equal "Please continue", args[1], "the deferred prompt must be carried to the retry"
    # ActiveJob stamps its own `_aj_symbol_keys` bookkeeping into each hash.
    assert_equal images, args[2]["images"].map { |image| image.except("_aj_symbol_keys") }
    assert_equal files, args[2]["files"].map { |file| file.except("_aj_symbol_keys") }

    scheduled_at = Time.zone.at(enqueued["at"] || enqueued[:at])
    retry_at = Time.zone.parse(@session.reload.metadata[SpotSessionHold::HELD_RETRY_AT])
    assert_in_delta retry_at.to_f, scheduled_at.to_f, 5,
                    "the re-check the session page promises is the one GoodJob will run"
  end

  test "the deferred turn runs once the gate reopens, carrying its original prompt" do
    run_job_with_held_gate(@session, "Please continue")
    assert_equal "waiting", @session.reload.status

    cli = run_job(@session, "Please continue", decision: allowed_decision)

    assert_equal 1, cli.resumed_sessions.length, "the deferred turn must actually be delivered"
    assert_includes cli.resumed_sessions.first[:prompt], "Please continue"
    @session.reload
    refute @session.metadata.key?(SpotSessionHold::HELD_REASON), "the hold is cleared once the turn runs"
  end

  test "a deferred turn is legible in the session's own log" do
    run_job_with_held_gate(@session, "Please continue")

    log = @session.logs.where(level: "warning").find { |entry| entry.content.include?("Spot session held") }
    assert_not_nil log, "a deferred turn must say so in the session's log"
    assert_includes log.content, "before its next turn"
    assert_includes log.content, "Make this one session priority to start it now."
  end

  # ---------------------------------------------------------------------------
  # What must keep working
  # ---------------------------------------------------------------------------

  test "a priority session's follow-up turn is untouched by a held gate" do
    @session.update!(scheduling_class: SessionGenesis::PRIORITY)

    cli = run_job_with_held_gate(@session, "Follow up question")

    assert_equal 1, cli.resumed_sessions.length, "priority work is never gated on quota"
    assert_equal "needs_input", @session.reload.status
  end

  test "promoting a held spot session to priority releases its next turn" do
    run_job_with_held_gate(@session, "Please continue")
    assert_equal "waiting", @session.reload.status

    @session.update!(scheduling_class: SessionGenesis::PRIORITY)
    cli = run_job_with_held_gate(@session, "Please continue")

    assert_equal 1, cli.resumed_sessions.length,
                 "promotion to priority is the sanctioned escape valve and must still work"
  end

  test "a resume is not deferred for a full fleet" do
    # The resuming session is ALREADY counted in Session.running_claude_code_count,
    # so refusing it for `fleet_at_cap` would refuse it on the strength of its own
    # slot — and would refuse every session the ceiling sweep resumes, since those
    # are flipped to `running` before their jobs run.
    cli = run_job(@session, "Please continue", decision: fleet_cap_decision)

    assert_equal 1, cli.resumed_sessions.length
    assert_equal "needs_input", @session.reload.status
  end

  test "a spot session's first start is still held at the starting line" do
    @session.update!(status: :waiting, session_id: nil, metadata: {})

    cli = run_job_with_held_gate(@session, nil)

    assert_empty cli.executed_commands
    @session.reload
    assert_equal "waiting", @session.status
    assert_equal SpotSessionHold::TURN_START, @session.metadata[SpotSessionHold::HELD_TURN]
  end

  test "a clone-only setup passes through a held gate" do
    @session.update!(status: :needs_input, prompt: nil, session_id: nil, metadata: {})

    cli = MockClaudeCliAdapter.new
    job = build_job(cli)
    job.file_system.mkdir_p(CLONE_PATH)

    SpotGateService.stub(:evaluate, held_decision) do
      GitCloneService.stub(:create_clone, { clone_path: CLONE_PATH, working_directory: CLONE_PATH }) do
        job.perform(@session.id, nil, resume_monitoring: false, clone_only: true)
      end
    end

    assert_empty cli.executed_commands, "a clone-only setup spawns no agent"
    @session.reload
    refute @session.metadata.key?(SpotSessionHold::HELD_REASON),
           "a clone-only setup spends no quota, so the gate has nothing to hold"
    assert_equal CLONE_PATH, @session.metadata["clone_path"], "the clone was set up despite the held gate"
  end

  test "a monitoring resume passes through a held gate" do
    # resume_monitoring re-attaches to a process that is already running. It starts
    # no turn and spends nothing, so holding it would only orphan the process.
    @session.merge_metadata!("process_pid" => 4242)

    job = build_job(MockClaudeCliAdapter.new)
    job.file_system.mkdir_p(CLONE_PATH)

    SpotGateService.stub(:evaluate, held_decision) do
      # Fails validation (no live process) and parks itself — the point is only that
      # it got past the gate rather than being held by it.
      job.perform(@session.id, nil, resume_monitoring: true)
    end

    @session.reload
    refute @session.metadata.key?(SpotSessionHold::HELD_REASON),
           "a monitoring resume must not be held: it starts no turn"
  end

  private

  def run_job_with_held_gate(session, prompt, images: nil, files: nil)
    run_job(session, prompt, decision: held_decision, images: images, files: files)
  end

  # Drive the real job for one turn against a stubbed gate decision, with the
  # runtime, the filesystem and the process manager mocked out.
  def run_job(session, prompt, decision:, images: nil, files: nil)
    cli = MockClaudeCliAdapter.new
    cli.resume_hook = ->(_opts) { { pid: 12_346, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }
    cli.execute_hook = ->(_opts) { { pid: 12_347, stderr_log_path: "#{CLONE_PATH}/claude_stderr.log" } }

    job = build_job(cli)
    job.file_system.mkdir_p(CLONE_PATH)
    job.file_system.write("#{CLONE_PATH}/claude_stderr.log", "")
    job.process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(0) ] }

    SpotGateService.stub(:evaluate, decision) do
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
            job.perform(session.id, prompt, images: images, files: files)
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

  def held_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "at_utilization_limit",
      detail: "Holding spot sessions: 5-hour window is at 87% of the 65% spot budget, averaged across all 4 accounts.",
      five_hour: nil, weekly: nil, active_sessions: 10, fleet_cap: 10,
      accounts_read: 4, pool_size: 4,
      fleet_burn_usd_per_minute: 1.2, candidate_burn_usd_per_minute: 0.4
    )
  end

  def fleet_cap_decision
    SpotGateService::Decision.new(
      allowed: false, reason: "fleet_at_cap",
      detail: "Holding spot sessions: 10 of 10 session slots taken.",
      five_hour: nil, weekly: nil, active_sessions: 10, fleet_cap: 10,
      accounts_read: 4, pool_size: 4,
      fleet_burn_usd_per_minute: 1.2, candidate_burn_usd_per_minute: 0.4
    )
  end

  def allowed_decision
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits",
      detail: "1 of 10 session slots taken, and 5-hour has $412.00 of spot budget left.",
      five_hour: nil, weekly: nil, active_sessions: 1, fleet_cap: 10,
      accounts_read: 4, pool_size: 4,
      fleet_burn_usd_per_minute: 0.4, candidate_burn_usd_per_minute: 0.4
    )
  end
end
