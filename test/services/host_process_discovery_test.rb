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

  # `ps ax` is stubbed on this one instance, the same way as `pgrep` above.
  test "claude_cli_processes keeps Claude CLI invocations from the ps listing" do
    @discovery.stubs(:ps_capture).returns([ <<~PS, stub(success?: true) ])
          PID COMMAND
         4242 claude -p --output-format stream-json
         4343 /usr/local/bin/claude --resume abc
         5151 claudette -p hello
         6161 vim notes-about-claude.md
    PS

    assert_equal [
      { pid: 4242, command: "claude -p --output-format stream-json" },
      { pid: 4343, command: "/usr/local/bin/claude --resume abc" }
    ], @discovery.claude_cli_processes
  end

  test "claude_cli_processes raises when ps fails rather than reporting an empty host" do
    @discovery.stubs(:ps_capture).returns([ "", stub(success?: false, exitstatus: 1) ])

    assert_raises(HostProcessDiscovery::ScanFailed) { @discovery.claude_cli_processes }
  end

  test "None sees nothing" do
    assert_equal [], HostProcessDiscovery::None.new.claude_processes
    assert_equal [], HostProcessDiscovery::None.new.claude_cli_processes
  end

  test "configured is blind in the test environment" do
    assert_equal :none, Rails.configuration.x.host_process_discovery

    assert_instance_of HostProcessDiscovery::None,
      HostProcessDiscovery.configured(process_manager: @process_manager, logger: @logger)
  end

  test "configured builds the host scanner under any other configuration" do
    original = Rails.configuration.x.host_process_discovery
    Rails.configuration.x.host_process_discovery = :host

    assert_instance_of HostProcessDiscovery,
      HostProcessDiscovery.configured(process_manager: @process_manager, logger: @logger)
  ensure
    Rails.configuration.x.host_process_discovery = original
  end
end
