# Transcript Hooks Configuration
# Register transcript hooks that analyze transcript content and update session custom_metadata
#
# Built-in hooks are registered automatically. To add custom hooks:
#
# 1. Create a hook class in app/services/transcript_hooks/ that inherits from TranscriptHooks::BaseHook
# 2. Add the registration line below
#
# Example:
#   TranscriptHooks::Registry.register(TranscriptHooks::MyCustomHook)
#
# For more details, see https://zimmer.tadasant.com/extend/transcript-hooks/

Rails.application.config.after_initialize do
  # Register built-in hooks
  TranscriptHooks::Registry.register_defaults!
end
