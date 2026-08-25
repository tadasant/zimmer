# frozen_string_literal: true

module Mcp
  # The tool catalog and its grouping system.
  #
  # A connection enables a set of *tool groups*; only the tools in those groups
  # are registered for it. This is how one endpoint serves the several scoped
  # variants Zimmer relies on:
  #
  #   (no groups)   → all base groups: the full surface
  #   sessions      → spawn/inspect/act on other sessions
  #   self_session  → the curated set auto-injected into every session, so a
  #                   session can manage itself (notes/title/heartbeat/archive),
  #                   notify its user, and schedule its own wake-ups
  #
  # Every domain group has a `_readonly` variant that drops write tools.
  #
  # A tool can belong to a composite group (self_session) in addition to its
  # domain group, and can register a *different class* when it comes in through
  # that composite group — that is how action_session narrows from the full
  # action list to the self-management subset in the self_session variant.
  module Registry
    BASE_GROUPS = %w[sessions notifications triggers health].freeze
    COMPOSITE_GROUPS = %w[self_session].freeze
    VALID_GROUPS = (BASE_GROUPS + BASE_GROUPS.map { |g| "#{g}_readonly" } + COMPOSITE_GROUPS).freeze

    Definition = Struct.new(:klass, :group, :write, :composite_groups, :composite_overrides, keyword_init: true) do
      def write? = write
      def composite_groups = self[:composite_groups] || []
      def composite_overrides = self[:composite_overrides] || {}
    end

    ALL_TOOLS = [
      # Sessions — reads
      Definition.new(klass: "Mcp::Tools::QuickSearchSessions", group: "sessions", write: false),
      Definition.new(klass: "Mcp::Tools::GetSession", group: "sessions", write: false, composite_groups: %w[self_session]),
      Definition.new(klass: "Mcp::Tools::GetConfigs", group: "sessions", write: false, composite_groups: %w[self_session]),
      # In self_session as well as sessions: with provenance offered on demand
      # rather than injected, the filtered self-session server is the only
      # surface every session carries, so a tool only on the full `zimmer`
      # server would leave those sessions no way to read their own record.
      Definition.new(klass: "Mcp::Tools::GetSessionProvenance", group: "sessions", write: false, composite_groups: %w[self_session]),
      Definition.new(klass: "Mcp::Tools::GetTranscriptArchive", group: "sessions", write: false),

      # Sessions — writes
      Definition.new(klass: "Mcp::Tools::StartSession", group: "sessions", write: true),
      Definition.new(
        klass: "Mcp::Tools::ActionSession",
        group: "sessions",
        write: true,
        composite_groups: %w[self_session],
        composite_overrides: { "self_session" => "Mcp::Tools::SelfSessionActionSession" }
      ),
      Definition.new(klass: "Mcp::Tools::ManageEnqueuedMessages", group: "sessions", write: true),
      Definition.new(klass: "Mcp::Tools::ManageCategories", group: "sessions", write: true),
      Definition.new(klass: "Mcp::Tools::RespondToElicitation", group: "sessions", write: true),
      # The Outcomes view's only write path. In `sessions` rather than a group of
      # its own so the already-registered `zimmer` and `zimmer-sessions` catalog
      # servers carry it unchanged — `zimmer-sessions` being the least-privileged
      # server an analysis session can be spawned with.
      Definition.new(klass: "Mcp::Tools::SaveOutcomeAnalysis", group: "sessions", write: true),

      # Notifications
      Definition.new(klass: "Mcp::Tools::GetNotifications", group: "notifications", write: false),
      Definition.new(klass: "Mcp::Tools::SendPushNotification", group: "notifications", write: true, composite_groups: %w[self_session]),
      Definition.new(klass: "Mcp::Tools::ActionNotification", group: "notifications", write: true),

      # Triggers
      Definition.new(klass: "Mcp::Tools::SearchTriggers", group: "triggers", write: false),
      Definition.new(klass: "Mcp::Tools::ActionTrigger", group: "triggers", write: true),
      Definition.new(klass: "Mcp::Tools::WakeMeUpLater", group: "triggers", write: true, composite_groups: %w[self_session]),
      Definition.new(klass: "Mcp::Tools::WakeMeUpWhenSessionChangesState", group: "triggers", write: true, composite_groups: %w[self_session]),

      # Health
      Definition.new(klass: "Mcp::Tools::GetSystemHealth", group: "health", write: false),
      Definition.new(klass: "Mcp::Tools::ActionHealth", group: "health", write: true),

      # Spot / priority scheduling. In `health` rather than `sessions` because
      # both tools are about the deployment's quota posture, not about one
      # session — and a self_session connection has no business rewriting the
      # global policy from inside a session it is being throttled by.
      # Costs is the ledger half of the same posture question GetSpotPolicy asks:
      # that one reads Anthropic's remaining headroom, this one reads what we
      # spent. Read-only, and fleet-wide, so it stays out of self_session.
      Definition.new(klass: "Mcp::Tools::GetCosts", group: "health", write: false),
      Definition.new(klass: "Mcp::Tools::GetSpotPolicy", group: "health", write: false),
      Definition.new(klass: "Mcp::Tools::ActionSpotPolicy", group: "health", write: true)
    ].freeze

    module_function

    # Parse a comma-separated group list. Blank means "all base groups" (the full
    # read+write surface), matching the decoupled server's TOOL_GROUPS default.
    # Unknown groups are dropped with a warning rather than failing the request.
    def parse_groups(value)
      groups = case value
      when nil then []
      when Array then value.map { |v| v.to_s.strip }
      else value.to_s.split(",").map(&:strip)
      end
      groups = groups.reject(&:empty?)

      return BASE_GROUPS.dup if groups.empty?

      known, unknown = groups.uniq.partition { |g| VALID_GROUPS.include?(g) }
      Rails.logger.warn("[Mcp::Registry] Unknown tool group(s): #{unknown.join(', ')}") if unknown.any?
      known
    end

    # The tool classes enabled for the given groups, in catalog order.
    def tools_for(groups)
      ALL_TOOLS.filter_map do |definition|
        next unless include?(definition, groups)
        resolve_class(definition, groups)
      end
    end

    def include?(definition, groups)
      return true if groups.include?(definition.group)
      return true if groups.include?("#{definition.group}_readonly") && !definition.write?
      definition.composite_groups.any? { |g| groups.include?(g) }
    end

    # Domain membership wins over a composite override: a connection with the
    # full `sessions` group gets the unrestricted action_session even if it also
    # enables self_session.
    def resolve_class(definition, groups)
      unless groups.include?(definition.group) || (groups.include?("#{definition.group}_readonly") && !definition.write?)
        override = definition.composite_groups.lazy
          .filter_map { |g| definition.composite_overrides[g] if groups.include?(g) }
          .first
        return override.constantize if override
      end

      definition.klass.constantize
    end
  end
end
