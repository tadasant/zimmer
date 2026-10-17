# frozen_string_literal: true

module LiveConversations
  # The live model's instructions, in this order:
  #
  # 1. the agent root's AGENTS.md, which owns the live agent's behaviour;
  # 2. a short section Zimmer writes about the mechanics only Zimmer knows — that
  #    the conversation can be typed or spoken and which it is now, the
  #    functions this conversation has, its URL;
  # 3. how to answer in the mode it is in right now: the root's own style file
  #    for that mode when it ships one (RootInstructions, `modes/<mode>.md`),
  #    Zimmer's short default (Mode#default_style) when it does not;
  # 4. for a voice call, which starts with no memory, what was already said;
  # 5. the Live mode guidance (LiveSetting#guidance), last so it reads as the
  #    newest word.
  #
  # All of it is rebuilt on every use — every text turn, every voice mint and
  # `session.update` — so a switch between typing and talking, or an edit to
  # the guidance, is in the very next answer. Text that differs between typed
  # and spoken belongs in the mode section; the guidance is the same on both.
  class SystemPrompt
    # How much of the thread so far a voice call is reminded of.
    RECAP_TURNS = 30
    RECAP_TURN_LIMIT = 600

    def self.build(conversation, recap: false, setting: LiveSetting.current) = new(conversation, setting: setting).build(recap: recap)

    def initialize(conversation, setting: LiveSetting.current)
      @conversation = conversation
      @setting = setting
    end

    def build(recap: false)
      sections = [ @conversation.instructions.to_s.strip, mechanics, mode_section ]
      sections << recap_section if recap
      sections << guidance_section
      sections.compact_blank.join("\n\n")
    end

    private

    def mechanics
      mode = @conversation.live_mode
      lines = [
        "## This conversation (written by Zimmer)",
        "",
        "- You are #{LABEL}, one continuous conversation with the person running this Zimmer. They can type or talk, " \
        "and switch between the two at any time; spoken turns in the thread are transcripts. Right now it is #{mode.voice? ? 'spoken' : 'typed'}.",
        "- Anything that takes more than about five seconds belongs in a background session: start it through the `#{ToolBridge::ZIMMER_TOOL}` function, say that you have, and keep talking. Check on it later with the same function.",
        "- To start one, call `#{ToolBridge::ZIMMER_TOOL}` with tool `quick_router` and a `prompt` saying what to do: it picks the agent root for you. Use `start_session` only when you know the exact agent root, and always pass both `agent_root` and `prompt`.",
        "- `#{ToolBridge::LIST_SERVERS}` and `#{ToolBridge::ENABLE_SERVER}` let you add a catalog MCP server to this conversation when you keep needing the same capability; its tools then appear as `<server>__<tool>` functions you call directly.",
        "- `#{ToolBridge::GET_SETTINGS}` and `#{ToolBridge::UPDATE_SETTINGS}` read and change your own settings: your models, your voice and speaking speed, turn detection, and the Live mode guidance below. When the person asks for a change (\"talk faster\", \"from now on, always …\"), make it — a standing instruction goes in with `append_guidance` — and tell them what you changed. Do not change them unasked.",
        "- Conversation: #{AppUrl.base_url}/live_conversations/#{@conversation.id}"
      ]
      lines.join("\n")
    end

    def guidance_section
      text = @setting.guidance_text
      return nil if text.empty?

      "## Live mode guidance\n\n" \
        "Standing instructions from the person you are talking to, edited on the Live settings page or with " \
        "`#{ToolBridge::UPDATE_SETTINGS}`. Follow them.\n\n#{text}"
    end

    # After AGENTS.md and the mechanics, so it is the freshest word on style: an
    # AGENTS.md written for one mode does not outvote the mode the conversation
    # is in.
    def mode_section
      mode = @conversation.live_mode
      style = @conversation.style_for(mode.key) || mode.default_style
      "## Right now: #{mode.voice? ? 'spoken' : 'typed'}\n\n" \
        "How to answer while the conversation is #{mode.voice? ? 'spoken' : 'typed'}. Where anything above says otherwise about style, this wins.\n\n" \
        "#{style.strip}"
    end

    # A voice call starts a fresh Realtime session, which remembers nothing —
    # whether it is reconnecting or the conversation was typed until now; this
    # is what it is told of the thread so far.
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
