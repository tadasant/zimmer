# frozen_string_literal: true

module Mcp
  module Tools
    # The read side of Live Mode and Live Voice: what /live and GET
    # /api/v1/live_conversations show — whether each mode can start, the recent
    # conversations, and one conversation's thread.
    class GetLiveConversations < Tool
      DEFAULT_TURNS = 40
      MAX_TURNS = 200
      LIST_LIMIT = 20

      tool_name "get_live_conversations"

      description <<~DESC
        Read Live Mode (typed) and Live Voice (spoken) conversations: one continuous thread per mode between the human and a fast OpenAI model that hands slow work to background sessions.

        - No "id": whether each mode can start (and why not), the current conversation per mode, and the most recent conversations.
        - With "id": that conversation's details and its newest turns — what was said, and every tool call it made with its output. Pass "after_turn_id" to read only turns newer than one you have seen.
      DESC

      input_schema({
        type: "object",
        properties: {
          id: { type: "number", description: "A live conversation's id. Omit to list." },
          mode: { type: "string", enum: LiveConversations::MODES.keys, description: "When listing, only this mode." },
          after_turn_id: { type: "number", description: "With id: only turns newer than this one." },
          turns: { type: "number", description: "With id: how many of the newest turns to return (default #{DEFAULT_TURNS}, max #{MAX_TURNS})." }
        }
      })

      def call(args)
        args["id"].present? ? show(args) : list(args["mode"])
      end

      private

      def list(mode)
        lines = [ "## Live modes", "" ]
        LiveConversations.mode_keys.each do |key|
          availability = LiveConversations::Availability.for(key)
          current = LiveConversation.current(key)
          state = availability.available? ? "available" : "off — #{availability.reasons.join(' ')}"
          lines << "- **#{availability.mode.label}** (`#{key}`, root `#{availability.mode.agent_root}`, model `#{availability.mode.model}`): #{state}" \
                   "#{current ? "; current conversation ##{current.id} (#{current.status})" : ''}"
        end

        scope = LiveConversation.recent_first.limit(LIST_LIMIT)
        scope = scope.for_mode(mode) if mode.present?
        lines += [ "", "## Recent conversations", "" ]
        lines << "None yet." if scope.empty?
        scope.each do |conversation|
          lines << "- ##{conversation.id} #{conversation.live_mode.label} — #{conversation.status}, #{conversation.turns.size} turns, " \
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
          "- **Mode:** #{conversation.live_mode.label}",
          "- **Status:** #{conversation.status}",
          "- **Agent root:** #{conversation.agent_root}",
          "- **Model:** #{conversation.model}",
          "- **Instructions:** #{conversation.instructions_source || '(not read yet)'}",
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
