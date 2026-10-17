# frozen_string_literal: true

module Mcp
  module Tools
    # The write half of /live/settings, through LiveConversations::SettingsUpdate
    # like every other writer. A change made here is recorded as an agent's,
    # naming the calling session when there is one.
    class ActionLiveSettings < Tool
      tool_name "action_live_settings"

      ACTIONS = %w[update reset restore_guidance].freeze

      description <<~DESC
        Change the Live settings — Live Mode's models, voice, speaking speed, turn detection, output caps — or the Live mode guidance appended to its instructions on every turn. Read them first with `get_live_settings`.

        **Actions:**
        - **update**: pass `settings`, an object of setting key → value (keys and choices as `get_live_settings` lists them; "default" puts one back), and/or `guidance` (replaces it) or `append_guidance` (adds a line). A model, voice or mode off the list is refused and nothing is saved; a number outside its range is clamped and the answer says so.
        - **reset**: every setting back to its default. The guidance is kept.
        - **restore_guidance**: the guidance as it was before change `change_id` (from `get_live_settings`' history).

        Changes apply from Live Mode's next turn, and an open voice call picks them up when its client next refreshes; the model, voice and voice reasoning effort apply from the next call. Every change is recorded in the history on /live/settings as an agent's.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS, description: "The action to perform" },
          settings: { type: "object", description: "update: setting key → value. Keys: #{LiveSetting::KEYS.join(', ')}." },
          guidance: { type: "string", description: "update: the whole Live mode guidance, replacing it. Empty clears it." },
          append_guidance: { type: "string", description: "update: a line to add to the Live mode guidance." },
          change_id: { type: "number", description: "restore_guidance: the history entry whose before-text to restore." }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action)
        raise ToolError, "Unknown action: #{action}. Valid actions: #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)

        result = case action
        when "update" then update(args)
        when "reset" then LiveConversations::SettingsUpdate.call({}, actor: actor, reset: true)
        when "restore_guidance" then restore_guidance(args)
        end
        result.changed? ? "Live settings updated.\n\n#{result.summary}" : "Nothing changed."
      rescue LiveConversations::SettingsUpdate::Invalid => e
        raise ToolError, "Nothing changed. #{e.message}"
      end

      private

      def update(args)
        settings = args["settings"] || {}
        raise ToolError, "\"settings\" must be an object." unless settings.is_a?(Hash)

        attributes = settings.merge(args.slice("guidance", "append_guidance"))
        raise ToolError, "Nothing to change: pass settings, guidance or append_guidance." if attributes.empty?

        LiveConversations::SettingsUpdate.call(attributes, actor: actor)
      end

      def restore_guidance(args)
        change = LiveSettingChange.find_by(id: require_arg(args, :change_id).to_i)
        raise ToolError, "No settings change ##{args['change_id']}." if change.nil?
        raise ToolError, "Change ##{change.id} did not touch the guidance." unless change.keys.include?("guidance")

        LiveConversations::SettingsUpdate.call({ "guidance" => change.before("guidance").to_s }, actor: actor)
      end

      def actor
        label = [ "MCP action_live_settings", ("session ##{context.self_session_id}" if context.self_session_id) ].compact.join(", ")
        LiveConversations::SettingsUpdate::Actor.agent(label)
      end
    end
  end
end
