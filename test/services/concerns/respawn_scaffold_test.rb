require "test_helper"
require "automated_prompts"

# Direct coverage for the scaffolding the four recovery services share.
#
# The four services exercise it end to end in their own tests; this file pins the
# pieces those tests reach only incidentally — the log sentences all four share, and
# the long-delay slicing that a service with a short delay never enters.
class RespawnScaffoldTest < ActiveJob::TestCase
  # A minimal host: the readers the module requires, plus its label.
  class TestHost
    include RespawnScaffold

    attr_reader :session, :process_manager, :log_buffer, :slept

    def initialize(session, process_manager, log_buffer, on_sleep: nil)
      @session = session
      @process_manager = process_manager
      @log_buffer = log_buffer
      @on_sleep = on_sleep
      @slept = []
    end

    # The module's methods are private; the tests drive them through these.
    def verify(pid, attempt) = verify_process_running(pid, attempt)
    def wait(delay, **kwargs) = wait_with_status_checks(delay, **kwargs)
    def status_check(**kwargs) = check_session_status(**kwargs)

    private

    def recovery_label = "test recovery"

    # Record rather than actually sleep, so the tests run in milliseconds.
    def sleep(seconds)
      @slept << seconds
      @on_sleep&.call(seconds)
    end
  end

  # A host that forgets to declare its label.
  class LabellessHost
    include RespawnScaffold

    def label = recovery_label
  end

  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
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

  # Turn @session into a status-summary fork of a freshly created source.
  def make_fork
    @source = Session.create!(
      prompt: "Route user requests to agent sessions",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
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
