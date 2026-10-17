# frozen_string_literal: true

module Mcp
  module Tools
    # The read side of Live Mode: what /live and GET /api/v1/live_conversations
    # show — whether it can start, the current and recent conversations, and one
    # conversation's thread.
    class GetLiveConversations < Tool
      DEFAULT_TURNS = 40
      MAX_TURNS = 200
      LIST_LIMIT = 20

      tool_name "get_live_conversations"

      description <<~DESC
        Read Live Mode conversations: one continuous thread between the human and a fast OpenAI model that hands slow work to background sessions. A conversation is typed or spoken (voice on) at any moment and can switch mid-thread.

        - No "id": whether Live Mode can start (and why not), the current conversation, and the most recent conversations.
        - With "id": that conversation's details and its newest turns — what was said, and every tool call it made with its output. Pass "after_turn_id" to read only turns newer than one you have seen.
      DESC

      input_schema({
        type: "object",
        properties: {
          id: { type: "number", description: "A live conversation's id. Omit to list." },
          after_turn_id: { type: "number", description: "With id: only turns newer than this one." },
          turns: { type: "number", description: "With id: how many of the newest turns to return (default #{DEFAULT_TURNS}, max #{MAX_TURNS})." }
        }
      })

      def call(args)
        args["id"].present? ? show(args) : list
      end

      private

      def list
        availability = LiveConversations::Availability.current
        current = LiveConversation.current
        lines = [
          "## #{LiveConversations::LABEL}",
          "",
          "- **State:** #{availability.available? ? 'available' : "off — #{availability.reasons.join(' ')}"}",
          "- **Agent root:** `#{LiveConversations::AGENT_ROOT}`",
          "- **Models:** #{LiveConversations::MODES.values.map { |mode| "#{mode.key} `#{mode.model}`" }.join(', ')}",
          "- **Current conversation:** #{current ? "##{current.id} (#{current.status}, #{current.live_mode.label.downcase})" : 'none'}"
        ]

        scope = LiveConversation.recent_first.limit(LIST_LIMIT)
        lines += [ "", "## Recent conversations", "" ]
        lines << "None yet." if scope.empty?
        scope.each do |conversation|
          lines << "- ##{conversation.id} #{conversation.display_title} (#{conversation.live_mode.label.downcase}) — #{conversation.status}, #{conversation.turns.size} turns, " \
                   "last activity #{conversation.last_activity_at&.iso8601 || 'never'} — #{context.base_url}/live_conversations/#{conversation.id}"
        end
        lines.join("\n")
      end

      def show(args)
        conversation = LiveConversation.find_by(id: args["id"]) || raise(ToolError, "Live conversation not found: #{args['id']}")
        limit = args["turns"].to_i.clamp(1, MAX_TURNS) if args["turns"].present?
        turns = conversation.turns
        turns = turns.where("id > ?", args["after_turn_id"].to_i) if args["after_turn_id"].present?
        turns = turns.reorder(id: :desc).limit(limit || DEFAULT_TURNS).to_a.reverse

        lines = [
          "## Live conversation ##{conversation.id}",
          "",
          "- **Mode:** #{conversation.live_mode.label.downcase}#{conversation.voice? ? ' (voice on)' : ''}",
          "- **Status:** #{conversation.status}",
          "- **Agent root:** #{conversation.agent_root}",
          "- **Model:** #{conversation.model}",
          "- **Instructions:** #{conversation.instructions_source || '(not read yet)'}",
          "- **Mode styles:** #{LiveConversations.mode_keys.map { |key| "#{key} from #{conversation.style_for(key) ? 'the agent root' : "Zimmer's default"}" }.join(', ')}",
          "- **MCP servers:** #{conversation.enabled_mcp_servers.join(', ').presence || 'none'}",
          "- **URL:** #{context.base_url}/live_conversations/#{conversation.id}"
        ]
        lines << "- **Error:** #{conversation.error_message}" if conversation.error_message.present?
        lines += [ "", "## Turns", "" ]
        lines << "None." if turns.empty?
        turns.each { |turn| lines << render_turn(turn) }
        lines.join("\n")
      end

      def render_turn(turn)
        if turn.tool?
          output = turn.tool_output.to_s.truncate(1_500)
          "- [#{turn.id}] **tool** `#{turn.tool_name}` #{JSON.generate(turn.tool_arguments || {})}#{turn.tool_error ? ' (failed)' : ''}\n  ```\n  #{output.gsub("\n", "\n  ")}\n  ```"
        else
          "- [#{turn.id}] **#{turn.role}**#{turn.source ? " (#{turn.source})" : ''}: #{turn.content}"
        end
      end
    end
  end
end
