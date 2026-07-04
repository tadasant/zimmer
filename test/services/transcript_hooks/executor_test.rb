require "test_helper"

class TranscriptHooks::ExecutorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @transcript_content = '{"type":"user","message":{"content":"Hello"}}'
    @new_messages = []

    # Save current state and clear for testing
    @original_hooks = TranscriptHooks::Registry.hooks.dup
    TranscriptHooks::Registry.clear!
  end

  teardown do
    # Restore original hooks
    TranscriptHooks::Registry.clear!
    @original_hooks.each { |hook| TranscriptHooks::Registry.register(hook) }
  end

  test "run_all executes all registered hooks" do
    TranscriptHooks::Registry.register(CountingHook)
    CountingHook.reset!

    executor = TranscriptHooks::Executor.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    results = executor.run_all

    assert_equal 1, CountingHook.call_count
    assert_equal 1, results.length
    assert results.first[:success]
  end

  test "run_all returns results for each hook" do
    TranscriptHooks::Registry.register(SuccessHook)
    TranscriptHooks::Registry.register(CountingHook)

    executor = TranscriptHooks::Executor.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    results = executor.run_all

    assert_equal 2, results.length
    assert results.all? { |r| r[:success] }
  end

  test "run_all handles hook errors gracefully" do
    TranscriptHooks::Registry.register(FailingHook)
    TranscriptHooks::Registry.register(CountingHook)
    CountingHook.reset!

    executor = TranscriptHooks::Executor.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    results = executor.run_all

    # Both hooks should be in results
    assert_equal 2, results.length

    # FailingHook should have failed
    failing_result = results.find { |r| r[:hook].include?("FailingHook") }
    assert_not failing_result[:success]
    assert_equal "Test error", failing_result[:error]

    # CountingHook should still have run
    assert_equal 1, CountingHook.call_count
  end

  test "run_all returns empty array when no hooks registered" do
    executor = TranscriptHooks::Executor.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: @new_messages
    )

    results = executor.run_all

    assert_empty results
  end

  # Test helper classes
  class SuccessHook < TranscriptHooks::BaseHook
    def call
      # No-op, just succeeds
    end
  end

  class CountingHook < TranscriptHooks::BaseHook
    @call_count = 0

    class << self
      attr_accessor :call_count

      def reset!
        @call_count = 0
      end
    end

    def call
      self.class.call_count += 1
    end
  end

  class FailingHook < TranscriptHooks::BaseHook
    def call
      raise "Test error"
    end
  end
end
