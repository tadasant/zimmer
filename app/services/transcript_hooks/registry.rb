# Registry for transcript hooks
# Manages registration and retrieval of transcript hook classes
#
# Usage:
#   # Register a hook (typically in config/initializers/transcript_hooks.rb)
#   TranscriptHooks::Registry.register(TranscriptHooks::GithubPrUrlHook)
#
#   # Get all registered hooks
#   TranscriptHooks::Registry.hooks
#
#   # Clear all hooks (useful for testing)
#   TranscriptHooks::Registry.clear!
#
class TranscriptHooks::Registry
  class << self
    # Register a hook class
    # @param hook_class [Class] A class that inherits from TranscriptHooks::BaseHook
    def register(hook_class)
      unless hook_class < TranscriptHooks::BaseHook
        raise ArgumentError, "#{hook_class} must inherit from TranscriptHooks::BaseHook"
      end

      hooks << hook_class unless hooks.include?(hook_class)
    end

    # Get all registered hooks
    # @return [Array<Class>] Registered hook classes
    def hooks
      @hooks ||= []
    end

    # Clear all registered hooks
    # Primarily for testing purposes
    def clear!
      @hooks = []
    end

    # Reset to default hooks
    # Re-registers the built-in hooks
    def reset!
      clear!
      register_defaults!
    end

    # Register default built-in hooks
    # Note: MCP connection failure detection is now handled by McpLogPollerService
    # which reads logs from the Claude CLI cache directory directly
    def register_defaults!
      register(TranscriptHooks::GithubPrUrlHook)
    end
  end
end
