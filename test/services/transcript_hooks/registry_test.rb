require "test_helper"

class TranscriptHooks::RegistryTest < ActiveSupport::TestCase
  setup do
    # Save current state and clear for testing
    @original_hooks = TranscriptHooks::Registry.hooks.dup
    TranscriptHooks::Registry.clear!
  end

  teardown do
    # Restore original hooks
    TranscriptHooks::Registry.clear!
    @original_hooks.each { |hook| TranscriptHooks::Registry.register(hook) }
  end

  test "register adds a hook to the registry" do
    TranscriptHooks::Registry.register(DummyHook)

    assert_includes TranscriptHooks::Registry.hooks, DummyHook
  end

  test "register prevents duplicate hooks" do
    TranscriptHooks::Registry.register(DummyHook)
    TranscriptHooks::Registry.register(DummyHook)

    assert_equal 1, TranscriptHooks::Registry.hooks.count { |h| h == DummyHook }
  end

  test "register raises error for non-BaseHook classes" do
    assert_raises(ArgumentError) do
      TranscriptHooks::Registry.register(String)
    end
  end

  test "clear! removes all hooks" do
    TranscriptHooks::Registry.register(DummyHook)
    TranscriptHooks::Registry.clear!

    assert_empty TranscriptHooks::Registry.hooks
  end

  test "register_defaults! adds built-in hooks" do
    TranscriptHooks::Registry.register_defaults!

    assert_includes TranscriptHooks::Registry.hooks, TranscriptHooks::GithubPrUrlHook
  end

  test "reset! clears and re-registers defaults" do
    TranscriptHooks::Registry.register(DummyHook)
    TranscriptHooks::Registry.reset!

    assert_not_includes TranscriptHooks::Registry.hooks, DummyHook
    assert_includes TranscriptHooks::Registry.hooks, TranscriptHooks::GithubPrUrlHook
  end

  # Test helper class
  class DummyHook < TranscriptHooks::BaseHook
    def call
      # No-op
    end
  end
end
