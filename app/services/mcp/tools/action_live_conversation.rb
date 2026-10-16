# frozen_string_literal: true

module Mcp
  module Tools
    # The write side of Live Mode and Live Voice that does not need a microphone:
    # what the /live pages' Start, Send and End buttons do, through the same rules
    # (LiveConversations::Start, LiveConversations::Actions).
    #
    # Not here, deliberately: Live Voice's relay (client secret, tool calls,
    # transcript lines) — those belong to a client holding an audio connection —
    # and the OpenAI key, which Zimmer does not manage on any surface: it is set
    # in the secrets console that administers the store.
    class ActionLiveConversation < Tool
      ACTIONS = %w[start send_message finish].freeze

      tool_name "action_live_conversation"

      description <<~DESC
        Start, message, or end a Live Mode / Live Voice conversation.

        **Actions:**
        - **start**: start a new conversation in "mode" ("text" for Live Mode, "voice" for Live Voice). Ends that mode's current conversation — each mode has one.
        - **send_message**: type "content" into a Live Mode conversation ("id"). The reply is written by a background job; read it with get_live_conversations.
        - **finish**: end a conversation ("id").
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS },
          mode: { type: "string", enum: LiveConversations::MODES.keys, description: "For start." },
          id: { type: "number", description: "The live conversation, for send_message and finish." },
          content: { type: "string", description: "For send_message." }
        },
        required: [ "action" ]
      })

      def call(args)
        case require_arg(args, :action)
        when "start" then start(args)
        when "send_message" then send_message(args)
        when "finish" then finish(args)
        else raise ToolError, "Unknown action \"#{args['action']}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      rescue LiveConversations::Actions::Refused, LiveConversations::Start::Unavailable => e
        raise ToolError, e.message
      end

      private

      def start(args)
        mode = require_arg(args, :mode).to_s
        raise ToolError, "mode must be one of: #{LiveConversations.mode_keys.join(', ')}" unless LiveConversations.mode_keys.include?(mode)

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
