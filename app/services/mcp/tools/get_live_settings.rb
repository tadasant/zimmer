# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of /live/settings: Live Mode's models, voice, speed, turn
    # detection and output caps, each with its choices or range, the Live mode
    # guidance, and the recent edit history.
    class GetLiveSettings < Tool
      HISTORY_LIMIT = 10

      tool_name "get_live_settings"

      description <<~DESC
        Read the Live settings — how Live Mode (typed and spoken) thinks, sounds and listens — and the Live mode guidance appended to its instructions on every turn.

        Lists every setting with its current value, whether that is the default, and its choices or range; then the guidance; then the newest changes and who made each (a person, or an agent: a live conversation's own model, or a session through MCP). Change them with `action_live_settings`.
      DESC

      input_schema({ type: "object", properties: {} })

      def call(_args)
        history = LiveSettingChange.recent_first.limit(HISTORY_LIMIT).map do |change|
          "- ##{change.id} #{change.created_at.utc.iso8601} — #{change.actor_kind}: #{change.actor} — #{change.keys.join(', ')}"
        end
        [
          "## Live settings",
          "",
          LiveSetting.current.describe,
          "",
          "### Recent changes",
          "",
          history.presence&.join("\n") || "None — everything is on its default.",
          "",
          "Page: #{context.base_url}/live/settings"
        ].join("\n")
      end
    end
  end
end
