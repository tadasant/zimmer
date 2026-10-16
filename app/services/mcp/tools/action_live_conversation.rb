# frozen_string_literal: true

module Mcp
  module Tools
    # The write side of Live Mode that does not need a microphone: what the /live
    # pages' Start, Send, Enable voice and End buttons do, through the same rules
    # (LiveConversations::Start, LiveConversations::Actions).
    #
    # Not here, deliberately: the voice relay (client secret, tool calls,
    # transcript lines) — those belong to a client holding an audio connection —
    # and the OpenAI key, which Zimmer does not manage on any surface: it is set
    # in the secrets console that administers the store.
    class ActionLiveConversation < Tool
      ACTIONS = %w[start send_message set_mode finish].freeze

      tool_name "action_live_conversation"

      description <<~DESC
        Start, message, switch, or end a Live Mode conversation. Live Mode has one current conversation, typed or spoken, and it can switch between the two mid-thread.

        **Actions:**
        - **start**: start a new conversation, typed unless "mode" is "voice". Ends the current conversation.
        - **send_message**: type "content" into a conversation ("id") while it is typed (voice off). The reply is written by a background job; read it with get_live_conversations.
        - **set_mode**: switch a conversation ("id") to "mode" — "voice" turns voice on (a client then opens the call), "text" turns it off. The model's instructions follow the mode: longer, formatted answers when typed; short, conversational ones when spoken.
        - **finish**: end a conversation ("id").
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS },
          mode: { type: "string", enum: LiveConversations::MODES.keys, description: "For set_mode (required) and start (default \"text\")." },
          id: { type: "number", description: "The live conversation, for send_message, set_mode and finish." },
          content: { type: "string", description: "For send_message." }
        },
        required: [ "action" ]
      })

      def call(args)
        case require_arg(args, :action)
        when "start" then start(args)
        when "send_message" then send_message(args)
        when "set_mode" then set_mode(args)
        when "finish" then finish(args)
        else raise ToolError, "Unknown action \"#{args['action']}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      rescue LiveConversations::Actions::Refused, LiveConversations::Start::Unavailable => e
        raise ToolError, e.message
      end

      private

      def start(args)
        mode = args["mode"].presence || "text"
        raise ToolError, mode_error unless LiveConversations.mode_keys.include?(mode.to_s)

        conversation = LiveConversations::Start.call(mode)
        "## Live conversation started\n\n- **ID:** #{conversation.id}\n- **Mode:** #{conversation.live_mode.label}\n" \
          "- **Status:** #{conversation.status} (reading #{conversation.agent_root}'s AGENTS.md)\n" \
          "- **URL:** #{context.base_url}/live_conversations/#{conversation.id}"
      end

      def send_message(args)
        conversation = find(args)
        turn = LiveConversations::Actions.new(conversation).post_message(require_arg(args, :content))
        "## Message sent\n\nTurn #{turn.id} on live conversation ##{conversation.id}. The reply arrives as a later turn."
      end

      def set_mode(args)
        conversation = find(args)
        mode = require_arg(args, :mode).to_s
        raise ToolError, mode_error unless LiveConversations.mode_keys.include?(mode)

        LiveConversations::Actions.new(conversation).switch_mode(mode)
        "## Live conversation ##{conversation.id} is #{conversation.voice? ? 'spoken (voice on)' : 'typed (voice off)'}\n\n" \
          "Model: `#{conversation.model}`. Its instructions follow the mode from the next answer."
      end

      def mode_error = "mode must be one of: #{LiveConversations.mode_keys.join(', ')}"

      def finish(args)
        conversation = find(args)
        LiveConversations::Actions.new(conversation).finish
        "## Live conversation ##{conversation.id} ended"
      end

      def find(args)
        id = require_arg(args, :id)
        LiveConversation.find_by(id: id) || raise(ToolError, "Live conversation not found: #{id}")
      end
    end
  end
end
