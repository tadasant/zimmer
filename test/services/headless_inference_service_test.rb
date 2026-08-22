# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class HeadlessInferenceServiceTest < ActiveSupport::TestCase
  setup do
    @service = HeadlessInferenceService.new
    @mock_process_manager = MockProcessManager.new
    @service.process_manager = @mock_process_manager
  end

  test "returns nil for blank prompt" do
    assert_nil @service.generate("")
    assert_nil @service.generate(nil)
    assert_nil @service.generate("   ")
  end

  test "runs the inference backend and returns the response" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      # Write mock output to the output file
      if options[:out].is_a?(Array)
        File.write(options[:out][0], "Generated Title")
      elsif options[:out].is_a?(String)
        File.write(options[:out], "Generated Title")
      end
    end

    @mock_process_manager.wait_hook = ->(pid, _flags) do
      [ pid, MockProcessManager::MockStatus.new(0) ]
    end

    result = @service.generate("Generate a title")

    assert_equal "Generated Title", result
    assert_equal 1, @mock_process_manager.spawned_processes.size
  end

  test "cleans response by removing common prefixes" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      if options[:out].is_a?(Array)
        File.write(options[:out][0], "Title: My Generated Title")
      elsif options[:out].is_a?(String)
        File.write(options[:out], "Title: My Generated Title")
      end
    end

    @mock_process_manager.wait_hook = ->(pid, _flags) do
      [ pid, MockProcessManager::MockStatus.new(0) ]
    end

    result = @service.generate("Generate a title")

    assert_equal "My Generated Title", result
  end

  test "removes surrounding quotes from response" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      if options[:out].is_a?(Array)
        File.write(options[:out][0], '"Quoted Title"')
      elsif options[:out].is_a?(String)
        File.write(options[:out], '"Quoted Title"')
      end
    end

    @mock_process_manager.wait_hook = ->(pid, _flags) do
      [ pid, MockProcessManager::MockStatus.new(0) ]
    end

    result = @service.generate("Generate a title")

    assert_equal "Quoted Title", result
  end

  test "takes only first line of multi-line response" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      if options[:out].is_a?(Array)
        File.write(options[:out][0], "First Line\nSecond Line\nThird Line")
      elsif options[:out].is_a?(String)
        File.write(options[:out], "First Line\nSecond Line\nThird Line")
      end
    end

    @mock_process_manager.wait_hook = ->(pid, _flags) do
      [ pid, MockProcessManager::MockStatus.new(0) ]
    end

    result = @service.generate("Generate a title")

    assert_equal "First Line", result
  end

  test "returns nil on timeout and terminates process" do
    @mock_process_manager.wait_hook = ->(_pid, _flags) do
      raise Timeout::Error, "Execution timed out"
    end

    result = @service.generate("Generate a title", timeout: 1)

    assert_nil result
    # Should have attempted to kill the process
    assert_equal 1, @mock_process_manager.killed_processes.size
    assert_equal "TERM", @mock_process_manager.killed_processes.first[:signal]
  end

  test "returns nil on error" do
    @mock_process_manager.spawn_hook = ->(_command, _options) do
      raise StandardError, "CLI not found"
    end

    result = @service.generate("Generate a title")

    assert_nil result
  end

  test "uses the current Claude-backed command structure" do
    # Headless inference is currently fulfilled by the Claude CLI in `-p` mode.
    # This pins the concrete backing command so a change to it is deliberate.
    command_captured = nil

    @mock_process_manager.spawn_hook = ->(command, options) do
      command_captured = command
      if options[:out].is_a?(Array)
        File.write(options[:out][0], "Response")
      elsif options[:out].is_a?(String)
        File.write(options[:out], "Response")
      end
    end

    @mock_process_manager.wait_hook = ->(pid, _flags) do
      [ pid, MockProcessManager::MockStatus.new(0) ]
    end

    @service.generate("Test prompt")

    assert_kind_of Array, command_captured
    assert command_captured.include?("claude")
    assert command_captured.include?("--dangerously-skip-permissions")
    assert_equal "opus", command_captured[command_captured.index("--model") + 1]
    assert command_captured.include?("-p")
    assert command_captured.include?("Test prompt")
  end

  test "uses floating opus alias instead of inheriting host default model" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      File.write(options[:out][0], "Response")
    end

    @service.generate("Test prompt")

    command = @mock_process_manager.spawned_processes.first[:command]
    assert_includes command, "--model"
    assert_equal ModelCatalog.default_for("claude_code"), command[command.index("--model") + 1]
    refute_match(/claude-opus-\d|opus-\d/, command.join(" "))
  end

  test "accepts custom timeout" do
    timeout_used = nil

    # Override timeout to capture the value
    @service.define_singleton_method(:generate) do |prompt, timeout: HeadlessInferenceService::DEFAULT_TIMEOUT|
      timeout_used = timeout
      nil # Return nil to avoid actual execution
    end

    @service.generate("Test", timeout: 60)

    assert_equal 60, timeout_used
  end

  test "default timeout is 30 seconds" do
    assert_equal 30, HeadlessInferenceService::DEFAULT_TIMEOUT
  end

  # THE GUARD THAT KEEPS A CLI ERROR OUT OF A COMPLETION.
  #
  # `claude -p` prints its own errors to STDOUT and exits non-zero — a usage
  # limit, a credit balance, an API error blob. A consumer reading only the text
  # would store the error as though it were the answer, and a status summary
  # stored that way is stamped CURRENT and never replaced. The exit status is the
  # wording-independent evidence, so it is checked before the text is believed.
  test "output from a backend that exited non-zero is discarded" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      target = options[:out].is_a?(Array) ? options[:out][0] : options[:out]
      File.write(target, "Claude AI usage limit reached|1755792000")
    end
    @mock_process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(1) ] }

    assert_nil @service.generate("Write the Status panel for this session")
  end

  # A backend that cannot report an exit code at all (the PTY transport drives a
  # TUI, not a one-shot process) leaves it nil, and nil must read as "unknown"
  # rather than "failed" — otherwise enabling that extension would silently
  # discard every completion.
  test "a backend that reports no exit status at all is still believed" do
    runner = Object.new
    runner.define_singleton_method(:run) do |prompt:, timeout:|
      ClaudePrintRunner::Result.new(text: "A real answer.", usage: nil, exit_status: nil)
    end
    ClaudePrintRunner.stub(:build, runner) do
      assert_equal "A real answer.", @service.generate("anything")
    end
  end

  # A `claude -p` that fails prints its OWN error to stdout — a usage limit, a
  # credit balance, an API error blob — and exits non-zero. Returning that text
  # would hand the caller an error dressed as a completion, which for the status
  # summary means storing it as the blurb and stamping it current.
  test "a non-zero exit discards whatever the backend printed" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      target = options[:out].is_a?(Array) ? options[:out][0] : options[:out]
      File.write(target, "Claude AI usage limit reached|1755792000")
    end
    @mock_process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(1) ] }

    assert_nil @service.generate("Summarize this session")
  end

  test "a zero exit returns the text as usual" do
    @mock_process_manager.spawn_hook = ->(_command, options) do
      target = options[:out].is_a?(Array) ? options[:out][0] : options[:out]
      File.write(target, "A real answer.")
    end
    @mock_process_manager.wait_hook = ->(pid, _flags) { [ pid, MockProcessManager::MockStatus.new(0) ] }

    assert_equal "A real answer.", @service.generate("Summarize this session")
  end
end
