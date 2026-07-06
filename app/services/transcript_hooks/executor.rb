# Executes all registered transcript hooks for a session
# Used by TranscriptPollerService to run hooks after polling transcripts
#
# Usage:
#   executor = TranscriptHooks::Executor.new(
#     session: session,
#     transcript_content: content,
#     new_messages: messages
#   )
#   executor.run_all
#
class TranscriptHooks::Executor
  attr_reader :session, :transcript_content, :new_messages

  def initialize(session:, transcript_content:, new_messages:)
    @session = session
    @transcript_content = transcript_content
    @new_messages = new_messages
  end

  # Run all registered hooks
  # Hooks are run sequentially and errors are logged but don't stop other hooks
  # @return [Array<Hash>] Results with hook name and success/error status
  def run_all
    results = []

    TranscriptHooks::Registry.hooks.each do |hook_class|
      result = run_hook(hook_class)
      results << result
    end

    results
  end

  private

  def run_hook(hook_class)
    hook = hook_class.new(
      session: session,
      transcript_content: transcript_content,
      new_messages: new_messages
    )

    hook.call
    { hook: hook_class.name, success: true }
  rescue => e
    Rails.logger.error "[TranscriptHooks] Error running #{hook_class.name}: #{e.message}"
    Rails.logger.error e.backtrace&.first(5)&.join("\n")
    { hook: hook_class.name, success: false, error: e.message }
  end
end
