# frozen_string_literal: true

module Mcp
  module Tools
    # The write half of Settings → Zimmer plugins: everything that page does.
    #
    # `mint_key` returns a secret, which is what sets it apart from the API keys
    # page (browser-only, so no key can mint a key). A plugin key reaches a subset
    # of what any key that can call this tool already reaches — invoking triggers —
    # so minting one over MCP widens nothing. The secret does land in the calling
    # session's context, and TranscriptRedactor masks the `zmr_` shape in the
    # stored transcript.
    #
    # A connection restricted with `allowed_agent_roots` may act only on a plugin
    # whose whole allowlist — before and after the change — is triggers of those
    # roots, the same scope `action_trigger` honours. Otherwise a restricted
    # connection could hand a plugin a trigger it cannot invoke itself.
    class ActionExternalApp < Tool
      ACTIONS = %w[create update delete mint_key revoke_key].freeze

      tool_name "action_external_app"

      description <<~DESC
        Register and manage Zimmer plugins (external apps): apps outside Zimmer whose key can invoke an
        allowlisted set of triggers and nothing else. The same operations as Settings → Zimmer plugins.

        Actions:
        - **create**: requires `name`; optional `description`, `enabled` (default true) and `trigger_ids`.
        - **update**: requires `id`; any of `name`, `description`, `enabled`, `trigger_ids`.
          `trigger_ids` REPLACES the allowlist (send [] to empty it). An id that names no trigger, or a
          workflow trigger, is an error and nothing is changed.
        - **delete**: requires `id`. Removes the plugin, its allowlist and its keys (they stop working
          at once). Sessions it started are kept.
        - **mint_key**: requires `id`. Creates a key and returns its secret — the only time it is ever
          shown. Store it where the app reads it; Zimmer keeps only a digest.
        - **revoke_key**: requires `id` and `key_id` (from search_external_apps). Refused from the next
          request on.

        A plugin's key connects to POST /mcp/external_app (tools list_triggers, invoke_trigger) or
        /api/v1/external_app/*, and is refused by every other route and by /mcp. Invoking behaves like
        the trigger's Invoke button — a disabled trigger can be invoked, and its max_sessions_per_minute
        applies — and every session a plugin creates records `external_app_id` and `external_app_name`
        in its metadata.
      DESC

      input_schema(
        type: "object",
        properties: {
          action: { type: "string", enum: ACTIONS },
          id: { type: "integer", description: "The plugin. Required for everything but create." },
          name: { type: "string", description: "Plugin name, unique. Stamped on every session it starts." },
          description: { type: "string", description: "What the app is." },
          enabled: { type: "boolean", description: "When false, every request with its keys is refused (403)." },
          trigger_ids: { type: "array", items: { type: "integer" }, description: "The full allowlist." },
          key_id: { type: "integer", description: "For revoke_key: the key's id." }
        },
        required: [ "action" ]
      )

      def call(args)
        case args["action"]
        when "create" then create(args)
        when "update" then update(args)
        when "delete" then delete(args)
        when "mint_key" then mint_key(args)
        when "revoke_key" then revoke_key(args)
        else raise ToolError, "Unknown action #{args['action'].inspect}. Use one of: #{ACTIONS.join(', ')}."
        end
      end

      private

      def create(args)
        app = ExternalApp.new(name: require_arg(args, "name").to_s.strip, description: args["description"].to_s.strip.presence)
        app.enabled = boolean(args["enabled"]) if args.key?("enabled")
        enforce_roots!(requested_triggers(args)) if args.key?("trigger_ids")
        ExternalApp.transaction do
          app.save!
          app.replace_triggers!(args["trigger_ids"]) if args.key?("trigger_ids")
        end
        audit("registered", app)
        { action: "create", external_app: SearchExternalApps.external_app_json(app.reload) }
      rescue ExternalApp::InvalidAllowlist => e
        raise ToolError, e.message
      rescue ActiveRecord::RecordNotUnique
        raise ToolError, "Validation failed: Name has already been taken"
      end

      def update(args)
        app = find_app(args)
        enforce_roots!(requested_triggers(args)) if args.key?("trigger_ids")
        ExternalApp.transaction do
          app.name = args["name"].to_s.strip if args.key?("name")
          app.description = args["description"].to_s.strip.presence if args.key?("description")
          app.enabled = boolean(args["enabled"]) if args.key?("enabled")
          app.save!
          app.replace_triggers!(args["trigger_ids"]) if args.key?("trigger_ids")
        end
        audit("updated", app, "enabled=#{app.enabled?} triggers=#{app.trigger_ids.sort.join(',')}")
        { action: "update", external_app: SearchExternalApps.external_app_json(app.reload) }
      rescue ExternalApp::InvalidAllowlist => e
        raise ToolError, e.message
      rescue ActiveRecord::RecordNotUnique
        raise ToolError, "Validation failed: Name has already been taken"
      end

      def delete(args)
        app = find_app(args)
        app.destroy!
        audit("deleted", app)
        { action: "delete", deleted: { id: app.id, name: app.name } }
      end

      def mint_key(args)
        app = find_app(args)
        api_key, token = app.mint_key!
        audit("minted a key for", app, "api_key_id=#{api_key.id}")
        {
          action: "mint_key",
          external_app: { id: app.id, name: app.name },
          key: { id: api_key.id, name: api_key.name, fingerprint: api_key.fingerprint, secret: token },
          note: "This is the only time the secret is shown. Send it as X-API-Key (or Authorization: Bearer) " \
                "to POST /mcp/external_app or /api/v1/external_app/*."
        }
      rescue ActiveRecord::RecordInvalid
        raise
      rescue ActiveRecord::ActiveRecordError => e
        raise ToolError, e.message
      end

      def revoke_key(args)
        app = find_app(args)
        key_id = require_arg(args, "key_id")
        api_key = app.api_keys.find_by(id: key_id)
        raise ToolError, "Plugin #{app.id} has no key with id #{key_id}" if api_key.nil?

        api_key.revoke!
        audit("revoked a key for", app, "api_key_id=#{api_key.id}")
        { action: "revoke_key", key: { id: api_key.id, name: api_key.name, revoked_at: api_key.revoked_at.iso8601 } }
      end

      # Every action but create names a plugin, and on a restricted connection
      # that plugin's current allowlist has to be inside the connection's roots.
      def find_app(args)
        id = require_arg(args, "id")
        app = ExternalApp.find_by(id: id) || raise(ToolError, "No Zimmer plugin with id #{id}")
        enforce_roots!(app.triggers)
        app
      end

      # The triggers a `trigger_ids` argument names that exist. Unknown ids are
      # left for ExternalApp#replace_triggers! to refuse with its own message.
      def requested_triggers(args)
        ids = Array(args["trigger_ids"]).map(&:to_s).select { |id| id.match?(/\A\d{1,18}\z/) }
        Trigger.where(id: ids).to_a
      end

      def enforce_roots!(triggers)
        triggers.each { |trigger| enforce_allowed_root!(trigger.agent_root_name) }
      end

      def boolean(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end

      # WARN, so it ships to obs — the same audit line the settings page writes.
      def audit(verb, app, detail = nil)
        Rails.logger.warn(
          "[external_app] #{verb} #{app.name.inspect} (external_app_id=#{app.id})#{" #{detail}" if detail} " \
          "via action_external_app#{" (session #{context.self_session_id})" if context.self_session_id}"
        )
      end
    end
  end
end
