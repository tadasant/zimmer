# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class HostProcessDiscoveryTest < ActiveSupport::TestCase
  setup do
    @process_manager = MockProcessManager.new
    @logger = StructuredLogger.new({ service: "HostProcessDiscoveryTest" })
    @discovery = HostProcessDiscovery.new(process_manager: @process_manager, logger: @logger)
  end

  # The `pgrep` call is stubbed on this one instance, never on Open3 for the whole
  # process — see "Flaky tests" in docs/operate/testing.md.
  test "parses pgrep output into pid, command and liveness" do
    @process_manager.set_process_state(4242, :running)
    @process_manager.set_process_state(4343, :dead)
    @discovery.stubs(:pgrep_output).returns(<<~PGREP)
      4242 claude --print --output-format stream-json
      4343 claude -p hello
    PGREP

    assert_equal [
      { pid: 4242, command: "claude --print --output-format stream-json", running: true },
      { pid: 4343, command: "claude -p hello", running: false }
    ], @discovery.claude_processes
  end

  # `pgrep -f claude` matches by substring, so it also lists a `claudette`; the
  # word-boundary filter is what keeps that out.
  test "skips this process, lines with no command, and substring matches" do
    @discovery.stubs(:pgrep_output).returns(<<~PGREP)
      #{Process.pid} claude
      99
      5151 claudette --serve
      6161 claude
    PGREP

    assert_equal [ 6161 ], @discovery.claude_processes.map { |process| process[:pid] }
  end

  test "a failed scan is an empty list, not an exception" do
    @discovery.stubs(:pgrep_output).raises(Errno::ENOENT, "pgrep")

    assert_equal [], @discovery.claude_processes
  end

  test "None sees nothing" do
    assert_equal [], HostProcessDiscovery::None.new.claude_processes
  end
end
