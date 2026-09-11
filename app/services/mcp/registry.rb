# frozen_string_literal: true

module Mcp
  # The tool catalog and its grouping system.
  #
  # A connection enables a set of *tool groups*; only the tools in those groups
  # are registered for it. This is how one endpoint serves the several scoped
  # variants Zimmer relies on:
  #
  #   (no groups)    → all base groups: the default surface
  #   sessions       → spawn/inspect/act on other sessions
  #   gate_decisions → read and append the agent gates' decision ledger.
  #                    OPT-IN: addressable, but never part of "no groups"
  #   outcome_analyses → start and stop Outcomes analyses. OPT-IN too
  #   settings       → read and change the Settings page's global defaults.
  #                    OPT-IN, like gate_decisions
  #   self_session   → the curated set auto-injected into every session, so a
  #                    session can manage itself (notes/title/heartbeat/archive),
  #                    notify its user, and schedule its own wake-ups
  #
  # Every domain group — base or opt-in — has a `_readonly` variant that drops
  # write tools.
  #
  # A tool can belong to a composite group (self_session) in addition to its
  # domain group, and can register a *different class* when it comes in through
  # that composite group — that is how action_session narrows from the full
  # action list to the self-management subset in the self_session variant.
  module Registry
    # The groups a connection gets when it asks for nothing. Not the whole
    # catalog — see OPT_IN_GROUPS.
    BASE_GROUPS = %w[sessions notifications triggers health].freeze

    # Domain groups a connection has to name to get. Valid and addressable —
    # they behave exactly like a base group once requested, `_readonly` variant
    # included — but deliberately outside the default-everything set, the way
    # COMPOSITE_GROUPS is. A group lands here when the cost of every unscoped
    # connection carrying its write tools outweighs the convenience.
    OPT_IN_GROUPS = %w[gate_decisions work_backlog outcome_analyses settings].freeze

    COMPOSITE_GROUPS = %w[self_session].freeze

    DOMAIN_GROUPS = (BASE_GROUPS + OPT_IN_GROUPS).freeze
    VALID_GROUPS = (DOMAIN_GROUPS + DOMAIN_GROUPS.map { |g| "#{g}_readonly" } + COMPOSITE_GROUPS).freeze

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
      # The Outcomes view's read side. Here rather than beside its write in
      # `outcome_analyses`: a read starts nothing, so it belongs on every surface
      # that can already read the transcript it describes — the unscoped `zimmer`
      # server, `zimmer-sessions`, and `sessions_readonly`. Not in self_session:
      # only an archived session has an analysis, so there is no "my own" one for
      # a live session to read.
      Definition.new(klass: "Mcp::Tools::GetOutcomeAnalysis", group: "sessions", write: false),
      # The dashboard's User view, as an agent reads it. In `sessions` rather than
      # a group of its own because it is a session listing — it just carries the
      # three facts a decision on that board turns on (the root, the generated
      # blurb, the PR and its CI) that `quick_search_sessions` rows do not.
      #
      # Note what is NOT here, and deliberately: there is no tool for the User
      # view's **Merge** button. That button is the one sanctioned route to an
      # agent merging its own work, and what sanctions it is that a human clicked
      # it. Be precise about what that buys: it is not a wall. The web UI has no
      # login (the network perimeter is the boundary) and `action_session`'s
      # `follow_up` delivers any text, the `[HUMAN-AUTHORIZED MERGE]` marker
      # included. What an agent cannot produce from this endpoint is the
      # HumanMessage the browser writes for the click, and that record — not the
      # marker — is the provenance an audit keys on. See Sessions::AuthorizeMerge.
      Definition.new(klass: "Mcp::Tools::GetUserView", group: "sessions", write: false),

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
      # The write half of the User view. Beside `change_precedence` rather than
      # replacing it: that one moves ONE session and is what a session uses on
      # itself, this one takes a whole ordering and is what the Reprioritize
      # button's session uses on the human's board.
      Definition.new(klass: "Mcp::Tools::ReorderUserView", group: "sessions", write: true),
      Definition.new(klass: "Mcp::Tools::ManageCategories", group: "sessions", write: true),
      Definition.new(klass: "Mcp::Tools::RespondToElicitation", group: "sessions", write: true),
      # How an analysis session hands its result back. In `sessions` rather than
      # with action_outcome_analysis so the already-registered `zimmer` and
      # `zimmer-sessions` catalog servers carry it unchanged — `zimmer-sessions`
      # being the least-privileged server an analysis session can be spawned with.
      # Saving is not starting: it spends nothing the analysis did not already.
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
      # spent. Read-only, and fleet-wide — which is why self_session gets a
      # composite OVERRIDE rather than the tool itself: SelfSessionGetCosts is
      # hard-scoped to the calling session and refuses the fleet and agent-root
      # forms, so a session can ask what it cost without being handed the
      # deployment's bill. Same precedent, and same shape, as
      # ActionSession -> SelfSessionActionSession above.
      Definition.new(
        klass: "Mcp::Tools::GetCosts",
        group: "health",
        write: false,
        composite_groups: %w[self_session],
        composite_overrides: { "self_session" => "Mcp::Tools::SelfSessionGetCosts" }
      ),
      Definition.new(klass: "Mcp::Tools::GetSpotPolicy", group: "health", write: false),
      Definition.new(klass: "Mcp::Tools::ActionSpotPolicy", group: "health", write: true),

      # Gate decisions — the pr-merge-gate / issue-work-gate ledger.
      #
      # AN OPT-IN GROUP OF ITS OWN (see OPT_IN_GROUPS). Folded into `sessions`
      # these would be offered to every session carrying `zimmer-sessions`, which
      # is most of them, and a ledger every session is handed a pen for is not
      # evidence of anything. Left in BASE_GROUPS it would be worse still: the
      # unscoped `/mcp` surface — the `zimmer` catalog entry, injected into roots
      # with `default_subagent_roots` — would carry the write, which is the
      # broadest reach in the deployment rather than the narrowest. So a
      # connection has to name `gate_decisions` to get the write;
      # `gate_decisions_readonly` — free, from the generated readonly variant —
      # gets the two reads and not the write. The group is meant for the two gate
      # roots' scoped servers — those roots live in a deployment's own catalog
      # rather than in Zimmer's, so `zimmer-gate-decisions` (mcp.json) is the entry
      # they attach, and no root in this repo's catalog attaches it.
      #
      # BE PRECISE ABOUT WHAT THAT BUYS. Tool groups are a SCOPING boundary, not an
      # authorization one: the API key is shared by the whole fleet and is written
      # into every session's own MCP config, so an agent that went looking could
      # compose its own `?tool_groups=` URL. What the group does is decide what a
      # session is *offered*, which is what keeps a rating from being something any
      # session can write in passing. The property that does not depend on the
      # caller behaving is the next paragraph.
      #
      # Note what is NOT here, on this group or any other: no tool writes human
      # feedback. That table has one writer, the browser controller, and it is not
      # reachable from this endpoint at all — see GateDecisionFeedback.
      #
      Definition.new(klass: "Mcp::Tools::SearchGateDecisions", group: "gate_decisions", write: false),
      Definition.new(klass: "Mcp::Tools::GetGateDecisionFeedback", group: "gate_decisions", write: false),
      Definition.new(klass: "Mcp::Tools::RecordGateDecision", group: "gate_decisions", write: true),

      # Work backlog — the ranked queue of gate-cleared issues the 04:00 groomer
      # starts work from.
      #
      # OPT-IN, FOR THE SAME REASON AS gate_decisions AND ONE MORE: the queue is
      # read by a job that spawns sessions from it with no human in the loop, so
      # an entry on it becomes an unattended implementing session. Folded into
      # `sessions`, every session carrying `zimmer-sessions` could enqueue work;
      # in BASE_GROUPS the unscoped `zimmer` surface could. So a connection has
      # to name `work_backlog` to append or pull; `work_backlog_readonly` gets the
      # read (what the Issues view and any analysis session needs) and not the
      # writes. `zimmer-work-backlog` (mcp.json) is the entry the gate and groomer
      # roots attach; those roots live in a deployment's own catalog.
      #
      # Note what is NOT here, on this group or any other: no tool pins an item,
      # hand-places one, or removes one by judgement. Those are a human's, and
      # exist only on the REST controller — see Api::V1::WorkBacklogItemsController.
      # Nor is there a "start now as priority" tool: promoting queued work to the
      # priority class is the human's lever over the spot queue, so it is REST only.
      Definition.new(klass: "Mcp::Tools::GetWorkBacklog", group: "work_backlog", write: false),
      Definition.new(klass: "Mcp::Tools::AppendWorkBacklogItem", group: "work_backlog", write: true),
      Definition.new(klass: "Mcp::Tools::PullWorkBacklogItems", group: "work_backlog", write: true),

      # Outcomes — starting and stopping analyses (Analyze, Analyze All, Stop).
      #
      # OPT-IN, AND THE REASON IS THE FEATURE'S OWN PREMISE: Zimmer analyzes nothing
      # implicitly, and every analysis is a full spot session. `analyze_all` turns
      # one call into a batch of them. Folded into `sessions`, every session
      # carrying `zimmer-sessions` could start one — including the analysis
      # sessions themselves, which are spawned with exactly that server, so an
      # analysis would hold the tool. In BASE_GROUPS the unscoped `zimmer` server
      # would carry it into every root that lists it. So a connection names
      # `outcome_analyses` to get it, and `zimmer-outcome-analyses` (mcp.json) is
      # the catalog entry that does; no root attaches it by default. As with
      # gate_decisions, this decides what a session is OFFERED, not what it can
      # reach: anything holding start_session or action_trigger can spawn a child
      # with that server. What bounds an agent that does are the limits below.
      #
      # The group holds only the write, so `outcome_analyses_readonly` is empty by
      # construction: the read, get_outcome_analysis, lives in `sessions` above.
      # The limits a caller meets once it is here — the concurrency cap, one
      # running batch, expected_count — are in ActionOutcomeAnalysis.
      Definition.new(klass: "Mcp::Tools::ActionOutcomeAnalysis", group: "outcome_analyses", write: true),

      # Settings — the Settings page's global defaults: the base runtime + model
      # and the Settings → Experimental toggles.
      #
      # OPT-IN, AND NOT IN `health` BESIDE THE SPOT POLICY THAT SHARES ITS ROW.
      # The spot policy decides how much work the fleet does; these decide what
      # every later session is created UNDER — which model it runs, whether it
      # searches MCP tools on demand, how its Claude credentials reach it, which
      # extensions reshape its spawn. A session that can write them changes the
      # harness its successors run in, so the write must not ride along on the
      # unscoped `zimmer` surface, and never on `self_session`. A connection
      # names `settings` to get the write; `settings_readonly` gets the read
      # alone. `zimmer-settings` / `zimmer-settings-readonly` (mcp.json) are the
      # catalog entries that name them, and no root carries either by default.
      #
      # A scoping boundary, as everywhere here, not an authorization one: the
      # fleet's shared API key can compose `?tool_groups=settings` itself. What
      # holds regardless is the `[AppSettings]` audit line every write leaves.
      Definition.new(klass: "Mcp::Tools::GetAppSettings", group: "settings", write: false),
      Definition.new(klass: "Mcp::Tools::ActionAppSettings", group: "settings", write: true)
    ].freeze

    module_function

    # Parse a comma-separated group list. Blank means "all base groups", matching
    # the decoupled server's TOOL_GROUPS default — which is every domain group
    # except the opt-in ones, so an unscoped connection never silently acquires a
    # group whose whole point is that you have to ask for it.
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
