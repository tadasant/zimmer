require "test_helper"
require "mocha/minitest"
require "automated_prompts"

# Direct coverage for the scaffolding the four recovery services share.
#
# The four services exercise it end to end in their own tests; this file pins the
# pieces those tests reach only incidentally — the log sentences all four share, and
# the long-delay slicing that a service with a short delay never enters.
class RespawnScaffoldTest < ActiveJob::TestCase
  # A minimal host: the readers the module requires, plus its three answers.
  class TestHost
    include RespawnScaffold

    attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :file_system, :slept, :next_attempts

    attr_accessor :attempt_limit

    def initialize(session, process_manager, log_buffer, on_sleep: nil, cli_adapter: nil, file_system: nil)
      @session = session
      @process_manager = process_manager
      @log_buffer = log_buffer
      @cli_adapter = cli_adapter
      @file_system = file_system
      @on_sleep = on_sleep
      @slept = []
      @next_attempts = []
      @attempt_limit = 3
      @logger = StructuredLogger.new({ session_id: session.id, service: "TestHost" })
    end

    # The module's methods are private; the tests drive them through these.
    def verify(pid, attempt) = verify_process_running(pid, attempt)
    def wait(delay, **kwargs) = wait_with_status_checks(delay, **kwargs)
    def status_check(**kwargs) = check_session_status(**kwargs)
    def respawn(dir, attempt, prompt:, &block) = respawn_and_verify(dir, attempt, resume_prompt: prompt, &block)
    def resume(dir, prompt:) = resume_for_recovery(dir, prompt: prompt)
    def transcript_path(dir) = find_transcript_path(dir)
    def line_count(dir) = get_transcript_line_count(dir)
    def message_text(entry) = extract_message_text(entry)

    private

    def recovery_label = "test recovery"

    def recovery_attempt_limit = @attempt_limit

    def next_recovery_attempt(working_directory)
      @next_attempts << working_directory
      :retried
    end

    # Record rather than actually sleep, so the tests run in milliseconds.
    def sleep(seconds)
      @slept << seconds
      @on_sleep&.call(seconds)
    end
  end

  # A host that forgets to declare the three answers the module asks for.
  class LabellessHost
    include RespawnScaffold

    def label = recovery_label
    def limit = recovery_attempt_limit
    def next_attempt = next_recovery_attempt("/tmp")
  end

  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid
    )
    @process_manager = MockProcessManager.new
    @log_buffer = LogBuffer.new(@session)
    @host = TestHost.new(@session, @process_manager, @log_buffer)
  end

  def logged
    @log_buffer.flush
    @session.logs.reload.map { |log| [ log.level, log.content ] }
  end

  # What the session's timeline holds RIGHT NOW, without flushing first — the only
  # way to observe whether the code under test flushed. `check_session_status`
  # documents flush ordering as load-bearing (a buffered line is stamped at flush
  # time, so an unflushed explanation lands after the event it explains), and a
  # `logged` that flushes on the test's behalf cannot tell a missing flush from a
  # present one.
  def already_persisted
    @session.logs.reload.map(&:content)
  end

  # Turn @session into a status-summary fork of a freshly created source.
  def make_fork
    @source = Session.create!(
      prompt: "Route user requests to agent sessions",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid
    )
    @session.update!(
      metadata: (@session.metadata || {}).merge(SessionStatusSummaryGenerator::FORK_MARKER => @source.id)
    )
  end

  # The prompt SessionStatusSummaryGenerator dispatches a fork with.
  def summary_request
    "#{SessionStatusSummaryGenerator::FORK_PROMPT_OPENING} (##{@source.id}). It is read at a glance."
  end

  test "verify_process_running returns true once the process has been up for the threshold" do
    @process_manager.running_hook = ->(_pid) { true }

    # The loop measures wall-clock elapsed time, so the stubbed sleep advances the
    # clock instead of burning SUCCESS_THRESHOLD seconds of real time.
    travel_to Time.current
    host = TestHost.new(@session, @process_manager, @log_buffer,
                        on_sleep: ->(seconds) { travel_to(Time.current + seconds, with_usec: true) })

    assert host.verify(4242, 1)
    # Ten half-second checks, not one early return: success is only declared after the
    # full stretch. Literals rather than the constant, so a broken threshold fails here.
    assert_equal [ 0.5 ] * 10, host.slept
    assert_empty logged
  end

  test "verify_process_running reports the death with the host's label, capitalized" do
    @process_manager.running_hook = ->(_pid) { false }

    refute @host.verify(4242, 2)

    entries = logged
    assert_equal 1, entries.length
    level, content = entries.first
    assert_equal "warning", level
    assert_match(/\ATest recovery attempt 2 failed — process 4242 died after \d+\.\ds\z/, content)
  end

  test "check_session_status aborts with the host's label when the session is no longer running" do
    @session.update!(status: :needs_input)

    assert_equal :aborted, @host.status_check
    assert_equal [ [ "warning", "Session state changed to needs_input during test recovery, aborting" ] ], logged
  end

  test "check_session_status stays quiet while the session is running" do
    assert_nil @host.status_check
    assert_empty logged
  end

  # THE SECOND DOOR (#724). The four services that mix this in respawn the runtime
  # from INSIDE a turn that is already running, so
  # `AgentSessionJob#refuse_non_summary_fork_turn` never sees them. A status-summary
  # fork holds a copy of its source's conversation, so a continuation prompt tells
  # it to continue the source's task — which is how router 4388's single
  # `start_session` call became sessions 11386 and 11391.
  test "check_session_status refuses a continuation prompt aimed at a status-summary fork" do
    make_fork

    assert_equal :aborted, @host.status_check(resume_prompt: AutomatedPrompts::SYSTEM_RECOVERY),
                 "resuming here replays the source's task and re-issues its side effects"

    level, content = logged.find { |(_, text)| text.include?("status-summary fork") }
    assert_not_nil content, "refused is not the same as silent"
    assert_equal "warning", level
    assert_includes content, "session #{@source.id}",
                    "the timeline should name whose work the resume would have continued"

    # THE HALF THAT IS EASY TO GET WRONG. `:aborted` means "somebody else owns this
    # exit", and every host maps it to an ExitDecision the job logs and walks away
    # from without transitioning anything. Returning it while leaving the fork
    # `running` would leave a fork with a dead process holding a full clone until a
    # sweep collected it. Pausing is what makes the `:aborted` claim true.
    refute @session.reload.running?, "a fork left `running` with a dead process is nobody's"
    assert @session.needs_input?, "pause is the fork's own completion transition"
  end

  # The load-bearing claim of the whole disposal: pausing is what fires the
  # harvest. Without this, reordering the pause hook's `after` block breaks the
  # blurb silently.
  test "the refused fork is harvested" do
    make_fork

    assert_enqueued_with(job: SessionStatusSummaryHarvestJob) do
      @host.status_check(resume_prompt: AutomatedPrompts::SYSTEM_RECOVERY)
    end
  end

  # THE OTHER DIRECTION, and the reason the test is the prompt rather than the
  # fork. A turn that was never spent arrives carrying the summary request and must
  # still run — `SigtermRetryService` prefers a `pending_follow_up_prompt` over the
  # recovery nudge, and for a fork interrupted before it consumed its prompt that
  # pending prompt IS the summary request. Refusing on the marker alone would cost
  # a blurb every time a deploy landed mid-generation.
  test "a fork's own summary request is not refused, so a never-spent turn still runs" do
    make_fork

    assert_nil @host.status_check(resume_prompt: summary_request),
               "refusing this costs the blurb the fork exists to write"
    assert @session.reload.running?, "and the fork must not be brought to rest either"
  end

  # `/compact` is what ContextLengthRetryService resumes with. It is not the
  # summary request, so it is refused like any other continuation.
  test "a compact resume is refused for a fork like any other continuation" do
    make_fork

    assert_equal :aborted, @host.status_check(resume_prompt: ContextLengthRetryService::COMPACT_PROMPT)
  end

  # A caller with no prompt to offer has not offered the summary request.
  test "an absent resume prompt is refused for a fork" do
    make_fork

    assert_equal :aborted, @host.status_check
  end

  test "the fork test does not fire for an ordinary session, whatever the prompt" do
    assert_nil @host.status_check(resume_prompt: AutomatedPrompts::SYSTEM_RECOVERY),
               "the interruption machinery is what rescues stranded sessions; it must be untouched"
    assert_empty logged
  end

  test "wait_with_status_checks does nothing at all for a zero delay" do
    # This is the case ContextLengthRetryService is in: no delay schedule, so no
    # wait and no status check here — it checks directly before spawning instead.
    assert_nil @host.wait(0)
    assert_empty @host.slept
    assert_empty logged
  end

  test "wait_with_status_checks sleeps a short delay in one go and checks once at the end" do
    assert_nil @host.wait(30)
    assert_equal [ 30 ], @host.slept
  end

  test "wait_with_status_checks aborts a short delay when the session stopped running" do
    # The only branch AuthRecoveryService ever takes, since its RETRY_DELAY is 2.
    @session.update!(status: :needs_input)

    assert_equal :aborted, @host.wait(30)
    assert_equal [ 30 ], @host.slept
  end

  test "wait_with_status_checks slices a long delay into status-check intervals" do
    assert_nil @host.wait(45)
    assert_equal [ 10, 10, 10, 10, 5 ], @host.slept
  end

  test "wait_with_status_checks abandons a long delay as soon as the session stops running" do
    slept = @host.slept
    @host.define_singleton_method(:check_session_status) { |**| slept.length >= 2 ? :aborted : nil }

    assert_equal :aborted, @host.wait(300)
    assert_equal [ 10, 10 ], slept
  end

  test "a host that declares no recovery_label fails loudly" do
    error = assert_raises(NotImplementedError) { LabellessHost.new.label }
    assert_match(/LabellessHost must define #recovery_label/, error.message)
  end

  test "a host that declares no recovery_attempt_limit fails loudly" do
    error = assert_raises(NotImplementedError) { LabellessHost.new.limit }
    assert_match(/LabellessHost must define #recovery_attempt_limit/, error.message)
  end

  test "a host that declares no next_recovery_attempt fails loudly" do
    error = assert_raises(NotImplementedError) { LabellessHost.new.next_attempt }
    assert_match(/LabellessHost must define #next_recovery_attempt/, error.message)
  end

  # ============================================================================
  # respawn_and_verify — the loop all four services run once they decide to act
  # ============================================================================

  # A host whose verification always succeeds without burning five real seconds.
  def verifying_host(cli_adapter: nil, file_system: nil)
    @process_manager.running_hook = ->(_pid) { true }
    travel_to Time.current
    TestHost.new(@session, @process_manager, @log_buffer,
                 on_sleep: ->(seconds) { travel_to(Time.current + seconds, with_usec: true) },
                 cli_adapter: cli_adapter, file_system: file_system)
  end

  test "respawn_and_verify records the process and reports success with the shared sentence" do
    host = verifying_host

    result = host.respawn("/tmp/clone", 2, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { { pid: 4242 } }

    assert_equal :success, result
    assert_equal 4242, @session.reload.metadata["process_pid"],
                 "the new pid has to be recorded, or the monitor watches the dead one"
    assert_empty host.next_attempts, "a verified re-spawn does not spend another attempt"

    contents = logged.map(&:last)
    assert_includes contents, "Spawned new agent process with PID 4242 for test recovery attempt 2"
    assert_includes contents, "Test recovery 2 successful - process 4242 verified running for 5s"
  end

  # The resume prompt is forwarded to `check_session_status`, not dropped: that
  # check is the SECOND DOOR of #724, and the prompt — not the fork marker — is
  # what it tests. Passing nil here would pause every status-summary fork whose
  # respawn carries its own never-spent summary request.
  test "respawn_and_verify refuses a fork whose respawn would replay its source" do
    make_fork
    spawned = false

    result = @host.respawn("/tmp/clone", 1, prompt: AutomatedPrompts::SYSTEM_RECOVERY) do
      spawned = true
      { pid: 4242 }
    end

    assert_equal :aborted, result
    refute spawned, "resuming here replays the source's task and re-issues its side effects"
  end

  test "respawn_and_verify still re-spawns a fork carrying its own summary request" do
    make_fork
    host = verifying_host

    assert_equal :success, host.respawn("/tmp/clone", 1, prompt: summary_request) { { pid: 4242 } },
                 "the prompt is the test, not the fork — a never-spent turn must still run"
    assert @session.reload.running?
  end

  test "respawn_and_verify flushes the timeline on its way out, on every path" do
    host = verifying_host
    assert_equal :success, host.respawn("/tmp/clone", 1, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { { pid: 4242 } }
    assert_includes already_persisted, "Test recovery 1 successful - process 4242 verified running for 5s",
                    "a success nobody flushed is a success nobody reads"

    @host.attempt_limit = 1
    assert_equal :exhausted, @host.respawn("/tmp/clone", 1, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { raise "boom" }
    assert_includes already_persisted, "Error during test recovery attempt 1: boom"
  end

  test "respawn_and_verify aborts before spawning when the session is no longer running" do
    @session.update!(status: :needs_input)
    spawned = false

    result = @host.respawn("/tmp/clone", 1, prompt: AutomatedPrompts::SYSTEM_RECOVERY) do
      spawned = true
      { pid: 4242 }
    end

    assert_equal :aborted, result
    refute spawned, "the abort check is the last gate BEFORE the spawn, not after it"
    assert_empty @host.next_attempts
  end

  test "respawn_and_verify hands on to the next attempt when the re-spawn dies during verification" do
    @process_manager.running_hook = ->(_pid) { false }

    result = @host.respawn("/tmp/clone", 1, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { { pid: 4242 } }

    assert_equal :retried, result
    assert_equal [ "/tmp/clone" ], @host.next_attempts
  end

  # The alerting decision the four services each carried a copy of the comment
  # for: an intermediate failure is .info (self-resolving, no alert), the final
  # one is .error (nothing left to recover it, so it must page).
  test "respawn_and_verify logs an intermediate failure at info and tries again" do
    @host.attempt_limit = 3

    result = @host.respawn("/tmp/clone", 2, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { raise "adapter blew up" }

    assert_equal :retried, result
    assert_equal [ "/tmp/clone" ], @host.next_attempts
    assert_equal [ [ "info", "Error during test recovery attempt 2: adapter blew up" ] ], logged
  end

  test "respawn_and_verify logs the final failure at error and gives up" do
    @host.attempt_limit = 3

    result = @host.respawn("/tmp/clone", 3, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { raise "adapter blew up" }

    assert_equal :exhausted, result
    assert_empty @host.next_attempts, "there is nothing left to try on the last attempt"
    assert_equal [ [ "error", "Error during test recovery attempt 3: adapter blew up" ] ], logged
  end

  test "respawn_and_verify catches a failure in the next attempt it delegated to" do
    @process_manager.running_hook = ->(_pid) { false }
    @host.define_singleton_method(:next_recovery_attempt) { |_dir| raise "the next attempt blew up too" }

    result = @host.respawn("/tmp/clone", 3, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { { pid: 4242 } }

    assert_equal :exhausted, result
    assert_includes logged.map(&:last), "Error during test recovery attempt 3: the next attempt blew up too"
  end

  test "a host may say something else about a verified re-spawn" do
    host = verifying_host
    host.define_singleton_method(:log_respawn_verified) do |pid, attempt|
      add_log("re-spawned #{pid} on attempt #{attempt}, but claiming nothing", level: "info")
    end

    assert_equal :success, host.respawn("/tmp/clone", 1, prompt: AutomatedPrompts::SYSTEM_RECOVERY) { { pid: 7 } }

    contents = logged.map(&:last)
    assert_includes contents, "re-spawned 7 on attempt 1, but claiming nothing"
    refute contents.any? { |text| text.include?("successful") },
           "AuthRecoveryService means something weaker by this; the scaffold must let it say so"
  end

  test "resume_for_recovery hands the runtime the prompt, the model and a rebuilt system prompt" do
    adapter = MockClaudeCliAdapter.new
    host = TestHost.new(@session, @process_manager, @log_buffer, cli_adapter: adapter)
    @session.update!(config: { "model" => "opus" })

    host.resume("/tmp/clone", prompt: "/compact")

    assert_equal 1, adapter.resumed_sessions.length
    resumed = adapter.resumed_sessions.first
    assert_equal @session.session_id, resumed[:session_id]
    assert_equal "/compact", resumed[:prompt]
    assert_equal "/tmp/clone", resumed[:working_dir]
    assert_equal "opus", resumed[:model]
    assert resumed[:append_system_prompt].present?,
           "a re-spawn told nothing about its goal or its root is a different session"
  end

  # ============================================================================
  # Reading the transcript the symptom was found in
  # ============================================================================

  test "find_transcript_path goes through the runtime's own source rather than a hardcoded path" do
    file_system = MockFileSystemAdapter.new
    host = TestHost.new(@session, @process_manager, @log_buffer, file_system: file_system)
    source = TranscriptRuntime.source_for(@session, file_system: file_system)
    directory = source.transcript_directory(working_directory: "/tmp/clone")
    file_system.mkdir_p(directory)
    file_system.write(File.join(directory, "#{@session.session_id}.jsonl"), "{}\n")

    assert_equal File.join(directory, "#{@session.session_id}.jsonl"), host.transcript_path("/tmp/clone")
  end

  # The whole reason step 3 waited for the TranscriptSource seam: a Claude path
  # baked into the extracted copy would find nothing for any other runtime.
  test "find_transcript_path follows the session's runtime, not Claude's layout" do
    @session.update!(agent_runtime: "codex")
    file_system = MockFileSystemAdapter.new
    host = TestHost.new(@session, @process_manager, @log_buffer, file_system: file_system)

    CodexTranscriptSource.any_instance.expects(:locate)
      .with(session: @session, working_directory: "/tmp/clone")
      .returns("/codex/rollout.jsonl")

    assert_equal "/codex/rollout.jsonl", host.transcript_path("/tmp/clone")
  end

  test "find_transcript_path answers nil rather than taking the recovery down with it" do
    file_system = MockFileSystemAdapter.new
    host = TestHost.new(@session, @process_manager, @log_buffer, file_system: file_system)
    TranscriptRuntime.stubs(:source_for).raises(Errno::EACCES, "/tmp/clone")

    assert_nil host.transcript_path("/tmp/clone")
  end

  test "get_transcript_line_count counts the lines of the located transcript" do
    file_system = MockFileSystemAdapter.new
    host = TestHost.new(@session, @process_manager, @log_buffer, file_system: file_system)
    source = TranscriptRuntime.source_for(@session, file_system: file_system)
    directory = source.transcript_directory(working_directory: "/tmp/clone")
    file_system.mkdir_p(directory)
    file_system.write(File.join(directory, "#{@session.session_id}.jsonl"), "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n")

    assert_equal 3, host.line_count("/tmp/clone")
  end

  test "get_transcript_line_count answers zero when there is no transcript to count" do
    file_system = MockFileSystemAdapter.new
    host = TestHost.new(@session, @process_manager, @log_buffer, file_system: file_system)

    assert_equal 0, host.line_count("/tmp/clone")
  end

  test "extract_message_text joins the entry's text blocks and ignores everything else" do
    entry = {
      "message" => {
        "content" => [
          { "type" => "text", "text" => "Prompt is too long" },
          { "type" => "tool_use", "name" => "Bash" },
          "a bare string",
          { "type" => "text", "text" => "and it stayed that way" }
        ]
      }
    }

    assert_equal "Prompt is too long and it stayed that way", @host.message_text(entry)
  end

  test "extract_message_text answers empty for entries that carry no prose" do
    assert_equal "", @host.message_text({})
    assert_equal "", @host.message_text({ "message" => "a string, not a hash" })
    assert_equal "", @host.message_text({ "message" => { "content" => "not an array" } })
  end

  test "every recovery service is built on the scaffold" do
    [
      SigtermRetryService,
      ApiErrorRetryService,
      ContextLengthRetryService,
      AuthRecoveryService
    ].each do |service|
      assert_includes service.ancestors, RespawnScaffold, "#{service} should include RespawnScaffold"
      assert_equal 5, service::SUCCESS_THRESHOLD
      assert_equal 10, service::STATUS_CHECK_INTERVAL
    end
  end
end
