# frozen_string_literal: true

module LiveConversations
  # A live conversation's scratchpad: short notes the live assistant keeps for
  # itself, so what it has been told stays in mind — "session 1234 cannot merge
  # yet; stop raising it". Every note goes into every turn's instructions, typed
  # and spoken (SystemPrompt#scratchpad_section), framed as the assistant's own
  # notes and not as instructions.
  #
  # Bound to one conversation and nothing else: a note lives on that row's
  # LiveScratchpadEntry rows, so it survives reconnecting, switching between
  # typing and talking, a deploy, and going back to the conversation later. A
  # new conversation starts with an empty pad.
  #
  # Who reaches it, and how:
  #
  # - the conversation's own assistant, through its `scratchpad` function
  #   (ToolBridge), which takes no conversation id — it can only ever touch its
  #   own pad;
  # - the person, on the conversation's page (/live_conversations/:id/scratchpad_entries)
  #   and through the iOS app's sign-in (Api::V1::LiveScratchpadEntriesController);
  # - an MCP client on the opt-in `live_conversations` group, which already reads
  #   and drives the whole thread (get_live_conversations, action_live_conversation).
  #
  # Agent sessions, including the ones the conversation starts, are not given it:
  # nothing on the default MCP surface reads it and nothing copies it into a
  # session's prompt.
  #
  # Bounded because it is in every turn: at most MAX_ENTRIES notes of
  # LiveScratchpadEntry::MAX_BODY_CHARS characters. A write past either is
  # refused with a message that says which and what to do — never cut short.
  class Scratchpad
    MAX_ENTRIES = 30

    class Refused < StandardError; end

    # @param written_by [String] one of LiveScratchpadEntry::WRITERS
    def initialize(conversation, written_by:)
      @conversation = conversation
      @written_by = written_by
    end

    def entries = @conversation.scratchpad_entries.to_a

    # @return [LiveScratchpadEntry]
    def add(text)
      body = checked_body(text)
      entry = @conversation.with_lock do
        count = @conversation.scratchpad_entries.count
        if count >= MAX_ENTRIES
          raise Refused, "The scratchpad is full (#{MAX_ENTRIES} notes). Remove a note that no longer holds, " \
                         "or edit one to fold this in, then add it again."
        end

        @conversation.scratchpad_entries.create!(body: body, written_by: @written_by)
      end
      changed!
      entry
    end

    # @return [LiveScratchpadEntry]
    def edit(id, text)
      body = checked_body(text)
      entry = find!(id)
      # Saving a note unchanged leaves it as its writer left it.
      return entry if entry.body == body

      entry.update!(body: body, written_by: @written_by)
      changed!
      entry
    end

    # @return [LiveScratchpadEntry] the removed note
    def remove(id)
      entry = find!(id)
      entry.destroy!
      changed!
      entry
    end

    # @return [Integer] how many notes were removed
    def clear
      count = @conversation.scratchpad_entries.delete_all
      changed! if count.positive?
      count
    end

    # The pad in plain text, for a function's or a tool's output.
    def listing
      list = entries
      return "The scratchpad is empty (0 of #{MAX_ENTRIES} notes)." if list.empty?

      "Scratchpad, #{list.size} of #{MAX_ENTRIES} notes:\n#{list.map { |entry| self.class.line(entry) }.join("\n")}"
    end

    WRITER_LABELS = { "assistant" => "you", "person" => "the person", "mcp" => "over MCP" }.freeze

    # One note as the model reads it: its id (which edit and remove take), who
    # wrote it, and when.
    def self.line(entry)
      "- (note #{entry.id}, #{WRITER_LABELS.fetch(entry.written_by, entry.written_by)}, " \
        "#{entry.updated_at.in_time_zone.strftime('%b %-d %H:%M')}) #{entry.body}"
    end

    private

    def checked_body(text)
      body = text.to_s.squish
      raise Refused, "A note needs some text." if body.empty?

      if body.length > LiveScratchpadEntry::MAX_BODY_CHARS
        raise Refused, "A note is at most #{LiveScratchpadEntry::MAX_BODY_CHARS} characters; this one is #{body.length}. " \
                       "Say it shorter, or split it into two notes."
      end

      body
    end

    def find!(id)
      @conversation.scratchpad_entries.find_by(id: id.to_s.delete_prefix("note").strip.to_i) ||
        raise(Refused, "This conversation's scratchpad has no note #{id}. Read the scratchpad for the notes it has.")
    end

    # The conversation page's panel follows every write, wherever it came from.
    def changed!
      @conversation.scratchpad_entries.reset
      BroadcastService.new(error_context: { source: "LiveConversations::Scratchpad##{@conversation.id}" }).broadcast_partial(
        action: :replace,
        stream: @conversation.stream_name,
        target: @conversation.scratchpad_dom_id,
        partial: "live_conversations/scratchpad",
        locals: { conversation: @conversation }
      )
    end
  end
end
