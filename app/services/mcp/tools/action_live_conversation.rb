# frozen_string_literal: true

module Mcp
  module Tools
    # The write side of Live Mode that does not need a microphone: what the /live
    # pages' Start, Go back, Send, Enable voice and End buttons do, through the
    # same rules (LiveConversations::Start, Switch, Actions).
    #
    # Not here, deliberately: the voice relay (client secret, tool calls,
    # transcript lines) — those belong to a client holding an audio connection —
    # and the OpenAI key, which Zimmer does not manage on any surface: it is set
    # in the secrets console that administers the store.
    class ActionLiveConversation < Tool
      ACTIONS = %w[start switch send_message set_mode finish scratchpad_add scratchpad_edit scratchpad_remove scratchpad_clear].freeze

      tool_name "action_live_conversation"

      description <<~DESC
        Start, go back to, message, or end a Live Mode conversation. Live Mode has one current conversation, typed or spoken, and it can switch between the two mid-thread.

        **Actions:**
        - **start**: start a new conversation, typed unless "mode" is "voice". Ends the current conversation.
        - **switch**: go back to an earlier conversation: its thread and its MCP servers return, it takes the mode of the conversation being left, and that one ends and can be gone back to the same way. Omit "id" for the one left most recently. Pass "from_id", the conversation you believe is current, and a stale selection is refused. A client on a call follows within seconds. Already current is a no-op; a failed conversation is refused.
        - **send_message**: type "content" into a conversation ("id") while it is typed (voice off). The reply is written by a background job; read it with get_live_conversations.
        - **set_mode**: switch a conversation ("id") to "mode" — "voice" turns voice on (a client then opens the call), "text" turns it off. The model's instructions follow the mode: longer, formatted answers when typed; short, conversational ones when spoken.
        - **finish**: end a conversation ("id").
        - **scratchpad_add** / **scratchpad_edit** / **scratchpad_remove** / **scratchpad_clear**: edit a conversation's ("id") scratchpad, the short notes its assistant reads on every turn — what not to bring up again, what is settled. Add takes "content"; edit takes "note_id" and "content"; remove takes "note_id". At most #{LiveConversations::Scratchpad::MAX_ENTRIES} notes of #{LiveScratchpadEntry::MAX_BODY_CHARS} characters; a write past either is refused. Read it with get_live_conversations.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS },
          mode: { type: "string", enum: LiveConversations::MODES.keys, description: "For set_mode (required), start (default \"text\") and switch (default: the mode of the conversation being left)." },
          id: { type: "number", description: "The live conversation, for send_message, set_mode and finish, and optionally switch." },
          from_id: { type: "number", description: "For switch: the conversation you believe is current, 0 for none." },
          content: { type: "string", description: "For send_message, scratchpad_add and scratchpad_edit." },
          note_id: { type: "number", description: "For scratchpad_edit and scratchpad_remove: the note's number." }
        },
        required: [ "action" ]
      })

      def call(args)
        case require_arg(args, :action)
        when "start" then start(args)
        when "switch" then switch(args)
        when "send_message" then send_message(args)
        when "set_mode" then set_mode(args)
        when "finish" then finish(args)
        when "scratchpad_add", "scratchpad_edit", "scratchpad_remove", "scratchpad_clear" then scratchpad(args)
        else raise ToolError, "Unknown action \"#{args['action']}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      rescue LiveConversations::Actions::Refused, LiveConversations::Start::Unavailable, LiveConversations::Scratchpad::Refused => e
        raise ToolError, e.message
      end

      private

      def start(args)
        mode = args["mode"].presence || "text"
        raise ToolError, mode_error unless LiveConversations.mode_keys.include?(mode.to_s)

        conversation = LiveConversations::Start.call(mode, client_surface: "mcp")
        "## Live conversation started\n\n- **ID:** #{conversation.id}\n- **Mode:** #{conversation.live_mode.label}\n" \
          "- **Status:** #{conversation.status} (reading #{conversation.agent_root}'s AGENTS.md)\n" \
          "- **URL:** #{context.base_url}/live_conversations/#{conversation.id}"
      end

      def switch(args)
        outcome = LiveConversations::Switch.call(args["id"], from_id: args["from_id"], mode: args["mode"], client_surface: "mcp")
        conversation = outcome.conversation
        return "## Already in live conversation ##{conversation.id}\n\nNothing changed." unless outcome.moved

        left = outcome.left.map { |row| "##{row.id}" }.join(", ").presence || "nothing was open"
        "## Back in live conversation ##{conversation.id}\n\n- **Called:** #{conversation.spoken_title}\n- **Mode:** #{conversation.live_mode.label}\n" \
          "- **Status:** #{conversation.status}\n- **Ended:** #{left}\n- **MCP servers:** #{conversation.enabled_mcp_servers.join(', ').presence || 'none'}\n" \
          "- **URL:** #{context.base_url}/live_conversations/#{conversation.id}"
      end

      def send_message(args)
        conversation = find(args)
        turn = LiveConversations::Actions.new(conversation, client_surface: "mcp").post_message(require_arg(args, :content))
        "## Message sent\n\nTurn #{turn.id} on live conversation ##{conversation.id}. The reply arrives as a later turn."
      end

      def set_mode(args)
        conversation = find(args)
        mode = require_arg(args, :mode).to_s
        raise ToolError, mode_error unless LiveConversations.mode_keys.include?(mode)

        LiveConversations::Actions.new(conversation, client_surface: "mcp").switch_mode(mode)
        "## Live conversation ##{conversation.id} is #{conversation.voice? ? 'spoken (voice on)' : 'typed (voice off)'}\n\n" \
          "Model: `#{conversation.model}`. Its instructions follow the mode from the next answer."
      end

      def mode_error = "mode must be one of: #{LiveConversations.mode_keys.join(', ')}"

      def finish(args)
        conversation = find(args)
        LiveConversations::Actions.new(conversation, client_surface: "mcp").finish
        "## Live conversation ##{conversation.id} ended"
      end

      # Written as `mcp`: a connection on this group may be the person's assistant
      # or one of the fleet's, and the pad says which surface wrote a note.
      def scratchpad(args)
        conversation = find(args)
        pad = LiveConversations::Scratchpad.new(conversation, written_by: "mcp")
        done = case args["action"]
        when "scratchpad_add" then "Added note #{pad.add(require_arg(args, :content)).id}."
        when "scratchpad_edit" then "Changed note #{pad.edit(require_arg(args, :note_id), require_arg(args, :content)).id}."
        when "scratchpad_remove" then "Removed note #{pad.remove(require_arg(args, :note_id)).id}."
        when "scratchpad_clear" then "Removed #{pad.clear} notes."
        end
        "## Scratchpad of live conversation ##{conversation.id}\n\n#{done}\n\n#{pad.listing}"
      end

      def find(args)
        id = require_arg(args, :id)
        LiveConversation.find_by(id: id) || raise(ToolError, "Live conversation not found: #{id}")
      end
    end
  end
end
