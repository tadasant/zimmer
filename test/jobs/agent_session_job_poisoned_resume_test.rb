# frozen_string_literal: true

require "test_helper"
require "path_sanitizer"
require_relative "../support/mock_process_manager"
require_relative "../support/mock_file_system_adapter"
require_relative "../support/mock_claude_cli_adapter"
require_relative "../support/mock_codex_runtime_adapter"

# The reproduction for zimmer#401, at the level the wedge actually happens: a turn
# that builds `--resume <id>` against a runtime session id no conversation was ever
# written under.
#
# Production session 3735's first job was killed ~40s in, before Claude Code had
# flushed its conversation. What it left on disk was a 126-byte file holding one
# `ai-title` record and no message. Every turn after that resumed into it, Claude Code
# answered "No conversation found with session ID: …" on stderr and exited 0, and
# Zimmer read that as a completed turn and parked the session in `needs_input` with an
# empty transcript. Three separate jobs behaved identically — the killed original,
# Zimmer's own recovery job, and an explicit `action_session` restart.
class AgentSessionJobPoisonedResumeTest < ActiveJob::TestCase
  CLONE = "/tmp/poisoned-resume-clone"
  POISONED_ID = "fef6a425-4e7f-4c16-9c0b-6308030114b1"

  setup do
    @session = Session.create!(
      prompt: "Post the alert triage summary to #alerts",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: POISONED_ID,
      transcript: nil,
      metadata: {
        "clone_path" => CLONE,
        "working_directory" => CLONE,
        "runtime_started" => true
      }
    )
  end

  # The exact file the killed first job left behind: Claude Code writes its title
  # record early and independently of any message, so the id is simultaneously too
  # present to create against and too empty to resume.
  def stub_transcript_only(mock_fs)
    write_runtime_transcript(
      mock_fs,
      { "type" => "ai-title", "aiTitle" => "Review Slack alerts", "sessionId" => @session.session_id }
    )
  end

  def real_transcript(mock_fs)
    write_runtime_transcript(mock_fs, { "type" => "assistant", "message" => { "content" => "On it" } })
  end

  def write_runtime_transcript(mock_fs, record)
    dir = File.join(File.expand_path("~"), ".claude", "projects", PathSanitizer.sanitize(CLONE))
    mock_fs.mkdir_p(dir)
    mock_fs.write(File.join(dir, "#{@session.session_id}.jsonl"), "#{record.to_json}\n")
  end

  # Runs one turn of the job the way a follow-up or a restart delivers one.
  def perform_turn(prompt)
    job = AgentSessionJob.new
    mock_pm = MockProcessManager.new
    mock_fs = MockFileSystemAdapter.new
    mock_fs.mkdir_p(CLONE)
    mock_fs.write("#{CLONE}/claude_stderr.log", "")
    mock_cli = MockClaudeCliAdapter.new
    mock_cli.process_manager = mock_pm
    mock_cli.file_system = mock_fs

    job.process_manager = mock_pm
    job.file_system = mock_fs
    job.cli_adapter = mock_cli

    yield mock_fs if block_given?

    job.perform(@session.id, prompt)
    @session.reload
    mock_cli
  end

  # ---------------------------------------------------------------------------
  # the guard
  # ---------------------------------------------------------------------------

  test "a turn on a session id that names no conversation spawns fresh instead of resuming it" do
    cli = perform_turn(AutomatedPrompts::SYSTEM_RECOVERY) { |fs| stub_transcript_only(fs) }

    assert_empty cli.resumed_sessions,
      "resuming a runtime session id whose transcript holds no conversation is the whole wedge: " \
      "Claude Code answers 'No conversation found with session ID' and exits 0"
    assert_operator cli.executed_commands.size, :>=, 1,
      "the turn must still run — it starts a fresh conversation rather than doing nothing"
    assert @session.logs.any? { |l| l.content.include?("holds no conversation") },
      "the decision must be legible on the session's own timeline"
  end

  test "the fresh spawn takes a new runtime session id, so the stub file cannot refuse it" do
    cli = perform_turn(AutomatedPrompts::SYSTEM_RECOVERY) { |fs| stub_transcript_only(fs) }

    assert_not_equal POISONED_ID, @session.session_id,
      "re-asserting --session-id against a transcript file that already exists is refused as " \
      "'Session ID … is already in use' (#519)"
    assert_not_equal POISONED_ID, cli.executed_commands.first[:session_id]
  end

  # Nothing on disk at all is the same question with a different answer shape — the
  # clone was recreated, or the runtime died before it opened the file.
  test "a session id with no transcript file at all is not resumed either" do
    cli = perform_turn(AutomatedPrompts::SYSTEM_RECOVERY)

    assert_empty cli.resumed_sessions
    assert_operator cli.executed_commands.size, :>=, 1
  end

  # A human's follow-up goes into the fresh conversation as written. Only the automated
  # nudge is substituted, because only the nudge names no task of its own.
  test "a human follow-up is delivered as written, never replaced by the session prompt" do
    cli = perform_turn("What did you find?") { |fs| stub_transcript_only(fs) }

    assert_empty cli.resumed_sessions
    assert_includes cli.executed_commands.first[:prompt].to_s, "What did you find?"
  end

  # A resume can also be reached with no follow-up at all, by reusing the clone. The
  # downgrade then lands on the initial-spawn branch, which REQUIRES a positional
  # prompt — a blank one is the nil argv element that crashed prod session 8698.
  test "a downgrade with no follow-up still carries a prompt into the initial spawn" do
    cli = perform_turn(nil) { |fs| stub_transcript_only(fs) }

    assert_empty cli.resumed_sessions
    assert_operator cli.executed_commands.size, :>=, 1
    assert_includes cli.executed_commands.first[:prompt].to_s, "Post the alert triage summary"
    assert_not @session.logs.any? { |l| l.content.include?("Refusing to spawn") },
      "the initial spawn must never be built without a prompt"
  end

  # ---------------------------------------------------------------------------
  # what the nudge is replaced with
  # ---------------------------------------------------------------------------

  test "the replayed turn carries the work and not the nudge as well" do
    cli = perform_turn(AutomatedPrompts::SYSTEM_RECOVERY) { |fs| stub_transcript_only(fs) }

    spawned = cli.executed_commands.first[:prompt].to_s
    assert_includes spawned, "Post the alert triage summary"
    assert_not_includes spawned, "continue where you left off",
      "the nudge is replaced, not appended — an agent told both is told to carry on with nothing"
  end

  # A human message the web UI stamped is cleared only once polling sees it land, so
  # one still sitting on a session with no conversation was never received by anybody.
  test "an undelivered human message is what gets replayed, ahead of the session prompt" do
    @session.merge_metadata!("sent_message" => "actually, check the staging config first")

    cli = perform_turn(AutomatedPrompts::SYSTEM_RECOVERY) { |fs| stub_transcript_only(fs) }

    spawned = cli.executed_commands.first[:prompt].to_s
    assert_includes spawned, "actually, check the staging config first",
      "replaying the original prompt over an undelivered message drops what the human asked for"
    assert_not_includes spawned, "Post the alert triage summary"
  end

  # HeartbeatSweepJob overwrites `session.prompt` with its own beat, so the prompt
  # column is not always a task. Swapping one nudge for another recovers nothing.
  test "a session whose prompt is itself a nudge is not 'recovered' by replaying it" do
    @session.update!(prompt: AutomatedPrompts::HEARTBEAT)

    cli = perform_turn(AutomatedPrompts::HEARTBEAT) { |fs| stub_transcript_only(fs) }

    assert_empty cli.resumed_sessions, "the fresh-start half of the fix still applies"
    assert_not @session.logs.any? { |l| l.content.include?("replays the work that never happened") },
      "there is no work to replay, and claiming otherwise in the log is worse than saying nothing"
  end

  # ---------------------------------------------------------------------------
  # the inverse: a real conversation must still be resumed
  # ---------------------------------------------------------------------------

  test "a session whose runtime wrote a conversation on disk is still resumed" do
    cli = perform_turn("What did you find?") { |fs| real_transcript(fs) }

    assert_equal 1, cli.resumed_sessions.size,
      "the guard must not abandon a conversation that exists"
    assert_equal POISONED_ID, cli.resumed_sessions.first[:session_id]
    assert_equal POISONED_ID, @session.session_id
  end

  test "a session whose stored transcript holds a conversation is still resumed" do
    @session.update!(transcript: %({"type":"user","message":{"content":"Hi"}}\n))

    cli = perform_turn("What did you find?") { |fs| stub_transcript_only(fs) }

    assert_equal 1, cli.resumed_sessions.size,
      "Zimmer's own copy is half the presence question: a lagging or broken on-disk " \
      "lookup must never be enough to abandon a real conversation"
  end
end

# The sharpest symptom on the issue: `action_session` with "restart" did not recover a
# wedged session. Not resuming the poisoned id is only half of that. The other half is
# the prompt — every restart path (the web UI button, the REST endpoint,
# `action_session`, the deploy and orphan sweeps) sends the SYSTEM_RECOVERY nudge, and
# "continue where you left off" names no task at all in a conversation that does not
# exist. The session would start over and immediately park again, having done nothing.
class RestartOfAWedgedSessionTest < ActiveJob::TestCase
  setup do
    # Unique per run: the turn asks the filesystem whether a conversation exists, so a
    # shared path could collide with another test's clone.
    @clone = "/tmp/wedged-restart-#{SecureRandom.hex(6)}"
    @session = Session.create!(
      prompt: "Post the alert triage summary to #alerts",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      transcript: nil,
      metadata: {
        "clone_path" => @clone,
        "working_directory" => @clone,
        "runtime_started" => true
      }
    )
  end

  # `action_session` with "restart" — the exact call that failed to recover session
  # 3735 — followed by the turn it queues.
  #
  # @param at_spawn [Proc, nil] called with the spawn's options as the runtime starts,
  #   for assertions about state that the end of the turn clears
  def restart_and_run_the_queued_turn(at_spawn: nil)
    output = Mcp::Tools::ActionSession
      .new(context: Mcp::Context.new(tool_groups: "sessions"))
      .call("action" => "restart", "session_id" => @session.id)
    assert_includes output, "Session Restarted"

    queued = enqueued_jobs.find { |j| j["job_class"] == "AgentSessionJob" }
    assert_not_nil queued, "the restart must queue a turn"
    prompt = ActiveJob::Arguments.deserialize(queued["arguments"])[1]
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, prompt,
      "restart delivers the recovery nudge — this is the turn that has to cope with it"

    job = AgentSessionJob.new
    mock_pm = MockProcessManager.new
    mock_fs = MockFileSystemAdapter.new
    mock_fs.mkdir_p(@clone)
    mock_fs.write("#{@clone}/claude_stderr.log", "")
    mock_cli = MockClaudeCliAdapter.new
    mock_cli.process_manager = mock_pm
    mock_cli.file_system = mock_fs
    if at_spawn
      mock_cli.execute_hook = lambda do |info|
        at_spawn.call(info)
        { pid: 31_337, stderr_log_path: "#{@clone}/claude_stderr.log" }
      end
    end
    job.process_manager = mock_pm
    job.file_system = mock_fs
    job.cli_adapter = mock_cli

    job.perform(@session.id, prompt)
    @session.reload
    mock_cli
  end

  test "restarting a wedged session runs the work it never did instead of resuming nothing" do
    cli = restart_and_run_the_queued_turn

    assert_empty cli.resumed_sessions,
      "resuming the poisoned runtime session id is why restart never recovered session 3735"
    assert_operator cli.executed_commands.size, :>=, 1
    assert_includes cli.executed_commands.first[:prompt].to_s, "Post the alert triage summary",
      "the nudge names no task in an empty conversation; the session's own prompt is the " \
      "work that never happened"
  end

  test "the replayed prompt is what a fresh start later in the same turn would replay too" do
    # Read at spawn time: the per-turn recovery slot is cleared when the turn ends.
    slot_at_spawn = nil
    restart_and_run_the_queued_turn(
      at_spawn: ->(_info) { slot_at_spawn = @session.reload.metadata["active_follow_up_prompt"] }
    )

    assert_includes slot_at_spawn.to_s, "Post the alert triage summary",
      "ProcessLifecycleManager#recovery_prompt prefers this slot, so leaving the nudge in it " \
      "would put the nudge straight back on the next fresh start"
  end

  # The inverse, because restart is also the ordinary "carry on" button: a session with
  # a conversation is resumed and nudged, exactly as before.
  test "restarting a session that has a conversation resumes it and still sends the nudge" do
    @session.update!(transcript: %({"type":"assistant","message":{"content":"Posted it"}}\n))

    cli = restart_and_run_the_queued_turn

    assert_equal 1, cli.resumed_sessions.size, "a conversation that exists must still be resumed"
    assert_includes cli.resumed_sessions.first[:prompt].to_s, "AUTOMATED SYSTEM MESSAGE",
      "nothing is replayed into a conversation that exists — the nudge is delivered as sent"
    assert_equal true, @session.metadata["runtime_started"]
  end
end

# The same wedge on a runtime that mints its own conversation id.
#
# Codex ignores the id Zimmer hands it and writes a brand-new rollout, so the stored
# id is a record of what the runtime chose rather than an instruction to it. Starting
# fresh while that stale id is still on the row would leave the poller reading the
# rollout the turn abandoned — CodexTranscriptSource#find_main_transcript prefers the
# file whose name carries the id — and Zimmer would report an empty transcript over a
# turn that really ran. ProcessLifecycleManager#fresh_start! releases the id for the
# same reason.
class CodexPoisonedResumeTest < ActiveJob::TestCase
  CLONE = "/tmp/poisoned-resume-codex"

  setup do
    @stale_rollout_id = SecureRandom.uuid
    @session = Session.create!(
      prompt: "Reconcile the billing rows",
      agent_runtime: "codex",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: @stale_rollout_id,
      transcript: nil,
      metadata: {
        "clone_path" => CLONE,
        "working_directory" => CLONE,
        "runtime_started" => true
      }
    )
  end

  def perform_turn(prompt)
    job = AgentSessionJob.new
    mock_pm = MockProcessManager.new
    mock_fs = MockFileSystemAdapter.new
    mock_fs.mkdir_p(CLONE)
    mock_fs.write("#{CLONE}/codex_stderr.log", "")
    mock_cli = MockCodexRuntimeAdapter.new
    mock_cli.process_manager = mock_pm
    mock_cli.file_system = mock_fs

    job.process_manager = mock_pm
    job.file_system = mock_fs
    job.cli_adapter = mock_cli

    job.perform(@session.id, prompt)
    @session.reload
    mock_cli
  end

  test "a Codex turn with no rollout to resume starts fresh and releases the stale id" do
    cli = perform_turn(AutomatedPrompts::SYSTEM_RECOVERY)

    assert_empty cli.resumed_sessions, "there is no rollout to `codex exec resume` into"
    assert_operator cli.executed_commands.size, :>=, 1
    assert_nil @session.session_id,
      "leaving the abandoned rollout id on the row keeps transcript polling reading it, so the " \
      "turn runs while Zimmer shows an empty transcript"
  end

  test "a Codex session with a conversation keeps its rollout id and is resumed" do
    @session.update!(transcript: %({"type":"message","role":"assistant","content":"working"}\n))

    cli = perform_turn("What did you find?")

    assert_equal 1, cli.resumed_sessions.size
    assert_equal @stale_rollout_id, @session.session_id,
      "releasing the id of a rollout that HAS a conversation would orphan real history"
  end
end
