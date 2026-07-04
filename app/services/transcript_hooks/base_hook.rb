# Base class for transcript hooks
# Transcript hooks analyze transcript content and can update session custom_metadata
#
# To create a new hook:
# 1. Create a new file in app/services/transcript_hooks/
# 2. Inherit from TranscriptHooks::BaseHook
# 3. Implement the #call method
# 4. Register in config/initializers/transcript_hooks.rb
#
# Example:
#   class TranscriptHooks::MyHook < TranscriptHooks::BaseHook
#     def call
#       # Analyze transcript_content and update custom_metadata
#       if transcript_content.include?("important pattern")
#         update_custom_metadata("my_key" => "extracted value")
#       end
#     end
#   end
#
class TranscriptHooks::BaseHook
  include DatabaseRetry

  attr_reader :session, :transcript_content, :new_messages

  def initialize(session:, transcript_content:, new_messages:)
    @session = session
    @transcript_content = transcript_content
    @new_messages = new_messages
  end

  # Override this method in subclasses to implement hook logic
  # @return [void]
  def call
    raise NotImplementedError, "Subclasses must implement #call"
  end

  protected

  # Helper to update custom_metadata on the session
  # Merges the provided hash with existing custom_metadata
  # Reloads session first to avoid overwriting concurrent updates
  # @param updates [Hash] The key-value pairs to merge into custom_metadata
  def update_custom_metadata(updates)
    return if updates.blank?

    with_db_retry do
      session.reload
      current = session.custom_metadata || {}
      session.update!(custom_metadata: current.merge(updates))
    end
  end

  # Helper to get a value from custom_metadata
  # Reloads session first to ensure fresh data
  # @param key [String] The key to retrieve
  # @return [Object, nil] The value or nil if not present
  def get_custom_metadata(key)
    session.reload
    session.custom_metadata&.dig(key)
  end

  # Parse the transcript content into message objects
  # @return [Array<Hash>] Parsed messages
  def parsed_transcript
    return [] unless transcript_content.present?

    transcript_content.lines.filter_map do |line|
      JSON.parse(line.strip)
    rescue JSON::ParserError
      nil
    end
  end

  # Extract all text content from transcript messages
  # @return [String] All text content concatenated
  def all_text_content
    @all_text_content ||= begin
      texts = []

      parsed_transcript.each do |message|
        message_data = message["message"] || message
        content = message_data["content"]

        case content
        when String
          texts << content
        when Array
          content.each do |block|
            texts << block["text"] if block["type"] == "text" && block["text"].present?
          end
        end
      end

      texts.join("\n")
    end
  end

  # Extract tool result content from transcript messages
  # Tool results are messages with type "user" where content is an array
  # containing objects with type "tool_result"
  # @return [String] All tool result content concatenated
  def tool_result_content
    @tool_result_content ||= begin
      texts = []

      parsed_transcript.each do |message|
        message_data = message["message"] || message
        content = message_data["content"]

        next unless content.is_a?(Array)

        content.each do |block|
          next unless block["type"] == "tool_result"

          result_content = block["content"]
          texts << result_content if result_content.is_a?(String)
        end
      end

      texts.join("\n")
    end
  end
end
