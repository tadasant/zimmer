# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of Settings → Zimmer plugins: every registered plugin, its
    # allowlist and its keys (never a key's secret — Zimmer does not have it).
    class SearchExternalApps < Tool
      tool_name "search_external_apps"

      description <<~DESC
        List Zimmer plugins (external apps): apps outside Zimmer whose key can invoke an allowlisted set of
        triggers and nothing else. For each: id, name, description, enabled, last_invoked_at, the
        allowlisted triggers (id, name, template variables, burst cap) and the keys (id, name,
        fingerprint, last used, revoked). Pass `id` for one plugin, or `query` to filter by name.

        A plugin's key connects to POST /mcp/external_app (tools list_triggers, invoke_trigger) or
        /api/v1/external_app/*. Change plugins with action_external_app.
      DESC

      input_schema(
        type: "object",
        properties: {
          id: { type: "integer", description: "Return just this plugin." },
          query: { type: "string", description: "Case-insensitive substring of the plugin name." }
        }
      )

      def call(args)
        scope = ExternalApp.listed.includes(:triggers, :api_keys)
        scope = scope.where(id: args["id"]) if args["id"].present?
        scope = scope.where("name ILIKE ?", "%#{ExternalApp.sanitize_sql_like(args['query'].to_s)}%") if args["query"].present?
        apps = scope.to_a
        raise ToolError, "No Zimmer plugin with id #{args['id']}" if args["id"].present? && apps.empty?

        { external_apps: apps.map { |app| self.class.external_app_json(app) } }
      end

      def self.external_app_json(app)
        {
          id: app.id,
          name: app.name,
          description: app.description.to_s,
          enabled: app.enabled?,
          last_invoked_at: app.last_invoked_at&.iso8601,
          created_at: app.created_at.iso8601,
          triggers: app.triggers.sort_by { |t| t.name.downcase }.map do |trigger|
            ExternalApps::Presenter.trigger_json(trigger).merge(workflow: trigger.workflow_backed?)
          end,
          keys: app.api_keys.sort_by(&:created_at).reverse.map do |key|
            {
              id: key.id,
              name: key.name,
              fingerprint: key.fingerprint,
              last_used_at: key.last_used_at&.iso8601,
              revoked_at: key.revoked_at&.iso8601,
              created_at: key.created_at.iso8601
            }
          end
        }
      end
    end
  end
end
