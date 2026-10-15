# frozen_string_literal: true

module LiveConversations
  # The live model's instructions: the agent root's AGENTS.md, which owns the
  # live agent's behaviour, followed by a short section Zimmer writes about the
  # mechanics only Zimmer knows — the mode, the functions this conversation
  # has, and (for a voice call that is reconnecting) what was already said.
  class SystemPrompt
    # How much of an earlier exchange a reconnecting voice call is reminded of.
    RECAP_TURNS = 30
    RECAP_TURN_LIMIT = 600

    def self.build(conversation, recap: false) = new(conversation).build(recap: recap)

    def initialize(conversation)
      @conversation = conversation
    end

    def build(recap: false)
      sections = [ @conversation.instructions.to_s.strip, mechanics ]
      sections << recap_section if recap
      sections.compact_blank.join("\n\n")
    end

    private

    def mechanics
      mode = @conversation.live_mode
      lines = [
        "## This conversation (written by Zimmer)",
        "",
        "- You are #{mode.label}, one continuous #{mode.voice? ? 'spoken' : 'typed'} conversation with the person running this Zimmer.",
        "- Anything that takes more than about five seconds belongs in a background session: start it through the `#{ToolBridge::ZIMMER_TOOL}` function, say that you have, and keep talking. Check on it later with the same function.",
        "- `#{ToolBridge::LIST_SERVERS}` and `#{ToolBridge::ENABLE_SERVER}` let you add a catalog MCP server to this conversation when you keep needing the same capability; its tools then appear as `<server>__<tool>` functions you call directly.",
        "- Conversation: #{AppUrl.base_url}/live_conversations/#{@conversation.id}"
      ]
      lines << "- Answer out loud: short sentences, no markdown, no URLs read aloud." if mode.voice?
      lines.join("\n")
    end

    # A reconnecting voice call starts a fresh Realtime session, which remembers
    # nothing; this is what it is told of the thread so far.
    def recap_section
      @recap_section ||= begin
        turns = @conversation.turns.where(role: %w[user assistant]).reorder(id: :desc).limit(RECAP_TURNS).to_a.reverse
        if turns.any?
          lines = turns.map { |turn| "#{turn.user? ? 'Them' : 'You'}: #{turn.content.to_s.squish.truncate(RECAP_TURN_LIMIT)}" }
          "## Earlier in this conversation\n\n#{lines.join("\n")}"
        end
      end
    end
  end
end
