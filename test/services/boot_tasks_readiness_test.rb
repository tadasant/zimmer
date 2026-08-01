require "test_helper"

class BootTasksReadinessTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir("boot_tasks_readiness_test")
    @marker = File.join(@tmpdir, "zimmer-boot-tasks-ready")
  end

  teardown do
    FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  # --- The gate is off unless the entrypoint armed it --------------------------

  test "await is disabled when the marker env var is unset" do
    with_marker_env(nil) do
      result = BootTasksReadiness.await(sleeper: ->(_) { flunk "must not sleep when disabled" })

      assert_equal :disabled, result.state
      assert result.ready?
      assert_not result.degraded?
      assert_equal 0.0, result.waited_seconds
    end
  end

  test "await is disabled when the marker env var is blank" do
    with_marker_env("   ") do
      assert_equal :disabled, BootTasksReadiness.await(sleeper: ->(_) { flunk "must not sleep" }).state
    end
  end

  # --- Marker already present: no waiting --------------------------------------

  test "await returns ready without sleeping when the marker already exists" do
    File.write(@marker, "ok\n")

    with_marker_env(@marker) do
      result = BootTasksReadiness.await(sleeper: ->(_) { flunk "must not sleep when the marker exists" })

      assert_equal :ready, result.state
      assert result.ready?
      assert_not result.waited?
    end
  end

  test "an empty or unreadable marker still counts as ready" do
    File.write(@marker, "")

    with_marker_env(@marker) do
      assert_equal :ready, BootTasksReadiness.await(sleeper: ->(_) { flunk "must not sleep" }).state
    end
  end

  # --- Marker reports a failed boot task ---------------------------------------

  test "await reports degraded when the marker names a failed boot task" do
    File.write(@marker, "claude-update-failed \n")

    with_marker_env(@marker) do
      result = BootTasksReadiness.await(sleeper: ->(_) { flunk "must not sleep" })

      assert_equal :degraded, result.state
      assert result.degraded?
      assert_not result.ready?
      assert_equal "claude-update-failed", result.detail
    end
  end

  test "degraded detail is truncated" do
    File.write(@marker, "x" * 500)

    with_marker_env(@marker) do
      result = BootTasksReadiness.await(sleeper: ->(_) { flunk "must not sleep" })

      assert_equal :degraded, result.state
      assert_equal BootTasksReadiness::MAX_DETAIL_CHARS, result.detail.length
    end
  end

  # --- Waiting -----------------------------------------------------------------

  test "await polls until the marker appears, then returns ready" do
    polls = 0
    sleeper = lambda do |seconds|
      assert_operator seconds, :<=, BootTasksReadiness::POLL_INTERVAL_SECONDS
      polls += 1
      File.write(@marker, "ok") if polls == 3
    end

    with_marker_env(@marker) do
      result = BootTasksReadiness.await(
        deadline_at: BootTasksReadiness.monotonic_now + 60,
        sleeper: sleeper
      )

      assert_equal :ready, result.state
      assert_equal 3, polls
    end
  end

  test "a marker present after the deadline still reads as ready" do
    File.write(@marker, "ok")

    with_marker_env(@marker) do
      result = BootTasksReadiness.await(
        deadline_at: BootTasksReadiness.monotonic_now - 1,
        sleeper: ->(_) { flunk "must not sleep when the marker exists" }
      )

      assert_equal :ready, result.state
    end
  end

  # --- The wait is bounded -----------------------------------------------------

  test "await times out rather than waiting forever when the marker never lands" do
    slept = []
    sleeper = ->(seconds) { slept << seconds; sleep(seconds) }

    with_marker_env(@marker) do
      result = BootTasksReadiness.await(
        deadline_at: BootTasksReadiness.monotonic_now + 0.05,
        sleeper: sleeper
      )

      assert_equal :timed_out, result.state
      assert result.degraded?
      assert_not result.ready?
    end

    assert_operator slept.sum, :<, 1.0, "the bounded wait must not sleep past its deadline"
  end

  test "a deadline already in the past means no wait at all" do
    with_marker_env(@marker) do
      result = BootTasksReadiness.await(
        deadline_at: BootTasksReadiness.monotonic_now - 1,
        sleeper: ->(_) { flunk "must not sleep once the deadline has passed" }
      )

      assert_equal :timed_out, result.state
    end
  end

  # --- Deadline configuration ---------------------------------------------------

  test "timeout defaults when unset, malformed, or negative" do
    [ nil, "", "abc", "-5" ].each do |value|
      with_env(BootTasksReadiness::TIMEOUT_ENV, value) do
        assert_equal BootTasksReadiness::DEFAULT_TIMEOUT_SECONDS, BootTasksReadiness.timeout_seconds,
          "expected the default timeout for #{value.inspect}"
      end
    end
  end

  test "timeout is operator-configurable, including down to zero" do
    with_env(BootTasksReadiness::TIMEOUT_ENV, "7.5") do
      assert_equal 7.5, BootTasksReadiness.timeout_seconds
    end

    with_env(BootTasksReadiness::TIMEOUT_ENV, "0") do
      assert_equal 0.0, BootTasksReadiness.timeout_seconds
    end
  end

  test "the default deadline is anchored to process start, not to the call" do
    with_env(BootTasksReadiness::TIMEOUT_ENV, "30") do
      assert_equal BootTasksReadiness::LOADED_AT + 30, BootTasksReadiness.default_deadline_at
    end
  end

  private

  def with_marker_env(value, &block)
    with_env(BootTasksReadiness::MARKER_ENV, value, &block)
  end

  def with_env(key, value)
    previous = ENV[key]
    had_key = ENV.key?(key)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
    yield
  ensure
    if had_key
      ENV[key] = previous
    else
      ENV.delete(key)
    end
  end
end
