require "test_helper"

# Direct coverage for the scaffolding the four recovery services share.
#
# The four services exercise it end to end in their own tests; this file pins the
# pieces those tests reach only incidentally — the log sentences every service now
# emits, and the long-delay slicing that a service with a short delay never enters.
class RespawnScaffoldTest < ActiveSupport::TestCase
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
    def wait(delay) = wait_with_status_checks(delay)
    def status_check = check_session_status

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

  test "verify_process_running returns true once the process has been up for the threshold" do
    @process_manager.running_hook = ->(_pid) { true }

    # The loop measures wall-clock elapsed time, so the stubbed sleep advances the
    # clock instead of burning SUCCESS_THRESHOLD seconds of real time.
    travel_to Time.current
    host = TestHost.new(@session, @process_manager, @log_buffer,
                        on_sleep: ->(seconds) { travel_to(Time.current + seconds, with_usec: true) })

    assert host.verify(4242, 1)
    assert_equal RespawnScaffold::SUCCESS_THRESHOLD, host.slept.sum
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

  test "wait_with_status_checks slices a long delay into status-check intervals" do
    assert_nil @host.wait(45)
    assert_equal [ 10, 10, 10, 10, 5 ], @host.slept
  end

  test "wait_with_status_checks abandons a long delay as soon as the session stops running" do
    slept = @host.slept
    @host.define_singleton_method(:check_session_status) { slept.length >= 2 ? :aborted : nil }

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
