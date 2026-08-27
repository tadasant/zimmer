# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST /api/v1/sessions: create a session, resolve the agent root's
    # catalog defaults onto it, and queue the agent job when a prompt is given.
    #
    # A restricted connection (allowed_agent_roots) may only spawn one of its
    # allowed roots, and must use that root's exact default MCP servers — the
    # same lock the decoupled server enforced from ALLOWED_AGENT_ROOTS.
    class StartSession < Tool
      tool_name "start_session"

      AGENT_RUNTIME_DESC = <<~TEXT.strip
        Per-spawn agent runtime override. Valid values are "claude_code" (Claude Code) and "codex" (OpenAI Codex CLI). When omitted, the session adopts the agent_root's default_runtime, then the global session default configured on the Settings page, then "claude_code". Call get_configs to see each agent root's default_runtime. Pair with `config.model` to pick a model valid for the chosen runtime (e.g. "opus"/"sonnet"/"haiku"/"fable" for claude_code, "gpt-5.6-sol"/"gpt-5.6-terra"/"gpt-5.6-luna" for codex).
      TEXT

      PROMPT_DESC = "Initial prompt for the agent. If provided, the agent job is automatically queued. Omit for a clone-only session."

      AGENT_ROOT_DESC = "Agent root name from get_configs. The API resolves git_root, branch, subdirectory, default_model, and other defaults from the agent root configuration. Always pass this so the session inherits the correct repository, model, and settings."

      TITLE_DESC = <<~TEXT.strip
        STRONGLY RECOMMENDED: Always set a title — treat it as effectively required. The title appears in the Zimmer web UI and push notifications, making sessions identifiable at a glance. Compose a short, descriptive title (under 70 characters) that captures what the session is doing (e.g. "Fix login redirect loop on mobile Safari", "Add dark mode toggle to settings page"). Only omit if you truly have zero context about the session purpose, which should be extremely rare.
      TEXT

      SLUG_DESC = "URL-friendly identifier for the session. Must be unique."

      GOAL_DESC = 'Goal ID from get_configs (e.g. "pr_merged"). The description is automatically resolved and passed to the agent as context.'

      EXECUTION_PROVIDER_DESC = 'Execution environment. Only option: "local_filesystem" — the agent runs on the Zimmer host itself, unsandboxed, with the host\'s git and gh credentials. Default: "local_filesystem"'

      MCP_SERVERS_DESC = 'List of MCP server names to enable for this session. Example: ["github-development", "slack"]'

      SKILLS_DESC = 'List of skill names to enable for this session. Always include the agent root\'s default_skills from get_configs as the starting point — omitting skills means the session gets none. Add extras as needed; removing a default should be rare and intentional. Example: ["discovery-classify", "publish-and-pr"]'

      PLUGINS_DESC = 'List of plugin names to enable for this session. Plugins extend agent capabilities with additional integrations. Example: ["my-plugin"]'

      HOOKS_DESC = 'List of catalog hook IDs to enable for this session. Hooks are shell commands the agent runtime fires on lifecycle events, so a hook that is noise for the task is worth dropping. Omitting hooks takes the agent root\'s default_hooks; pass [] to select none. A plugin can bundle hooks of its own, and those are added on top of this list — to drop a hook a selected plugin bundles, narrow `plugins` too. Example: ["git-push-ci-reminder"]'

      CONFIG_DESC = <<~TEXT.strip
        Additional configuration as a JSON object. Use `config.model` to choose the agent model for this session (e.g. {"model": "gpt-5.6-terra"} for a codex runtime, or {"model": "fable"} for claude_code). The model must be valid for the resolved agent_runtime; call get_configs to see each agent root's default_model. When omitted, the session uses the agent root's default_model, then the global session default configured on the Settings page, then the runtime's catalog default; a model that is not valid for the resolved runtime is replaced by that fallback. An explicit config.model always takes precedence.
      TEXT

      CUSTOM_METADATA_DESC = "User-defined metadata as a JSON object. Useful for tracking tickets, projects, etc."

      PARENT_SESSION_ID_DESC = <<~TEXT.strip
        ID of the session spawning this one. Records the spawn edge that the dependency graph uses and that the session hierarchy is built from: the new session sees the human messages recorded anywhere in its hierarchy, each marked with the session it was authored in, so a human's original intent reaches the session doing the work. Set this whenever you start a session on behalf of work you were asked to do — a router composing a spawn prompt is a machine author, so without the edge the new session has no record of the human who set the work in motion.
      TEXT

      SCHEDULING_CLASS_DESC = <<~TEXT.strip
        Spot/priority class for THIS session, overriding whatever its origin would give it. `priority` starts whenever it is ready; `spot` starts only while a Claude Code account is under both quota targets and a session slot is free, and otherwise waits and starts later (it is deferred, never cancelled). Omit this and the session inherits its parent's explicit class if there is one, and otherwise derives from its genesis — which for a spawn under a `slack` parent means priority. Pass "spot" when you are spawning long, unattended, low-urgency work (a big batch, a sweep, a backfill) that nobody is waiting on, so it does not compete with work a human is watching. Read the current policy with `get_spot_policy`.
      TEXT

      PRECEDENCE_DESC = PrecedenceDocs::START_SESSION

      IDEMPOTENCY_KEY_DESC = <<~TEXT.strip
        Names THIS create attempt so it is safe to retry. Invent a string that is unique to the unit of work you are spawning (a UUID, or something like "issue-577-fix-2026-08-27") and pass it. If the call errors — including a gateway timeout, where the session may well have been created before the response was lost — call start_session again with the SAME key: Zimmer returns the session the first call made instead of creating a second one, and never queues a second agent. Without a key there is no way to tell a create that never landed from one whose response was lost, and retrying spawns a duplicate. Max #{Session::IDEMPOTENCY_KEY_MAX_LENGTH} characters. The key is not a fingerprint of the arguments: reusing one for genuinely different work returns the first session, so use a fresh key for each new unit of work.
      TEXT

      AUTO_COMPACT_WINDOW_DESC = <<~TEXT.strip
        Optional per-session auto-compact (context) window override, in tokens. **You should generally rely on the default of 200,000** — omit this parameter and the API default applies. Only override in the rare situation where the spawned session is suffering from compaction thrashing because it doesn't have enough space to work — in that case, retry with `1000000` (1 million tokens). Compaction thrashing is currently the only known reason to set this preemptively.
      TEXT

      description <<~DESC
        Start a new agent session in the Zimmer.

        **IMPORTANT:** Before starting a session, call get_configs to discover available agent roots, MCP servers, goals, and their defaults.

        **Returns:** The created session with its ID, status, and configuration.

        **Behavior:**
        - If a prompt is provided, the agent job is automatically queued to start
        - If no prompt is provided, creates a clone-only session that can be started later with action_session

        **Agent Roots:** Use `agent_root` to specify which preconfigured agent root to use. The API resolves git_root, branch, subdirectory, default_model, and other defaults from the agent root configuration.

        **Defaults from Agent Roots:** The agent root defines `default_mcp_servers`, `default_skills`, `default_hooks`, `default_plugins`, and optionally a `default_goal`. Omitting `mcp_servers`, `skills`, `plugins`, or `hooks` means the session takes the root's defaults for that list. Passing an explicit empty array (`[]`) means the session gets NONE of that artifact — omitted and `[]` are two different requests, not the same one.

        - **MCP servers:** Start with `default_mcp_servers`. Drop servers the task doesn't need (least-privilege) by passing the narrowed list; pass `[]` when the task needs no servers at all. When this connection is restricted to specific agent roots, you cannot add or remove servers — the list you pass must match the root's defaults exactly, and `[]` is rejected unless the root has no defaults.
        - **Skills:** Start with `default_skills`. You can freely add skills beyond the defaults. Removing a default skill should be rare and intentional — only when you have a specific reason, like replacing a skill with a more capable variant that covers the same ground. Skills are lightweight text files with no blast radius, so keeping all defaults costs nothing.
        - **Hooks:** Start with `default_hooks`. Drop one when it fires on work this session won't do (a CI-reminder hook on a docs-only task, say) by passing the narrowed list, or `[]` to select none. Selecting no hooks is not the same as running with none: a plugin bundles hooks of its own, and those are added on top of the list you pass, so dropping a hook a selected plugin bundles means narrowing `plugins` as well.

        **Runtime and model selection:** Pass `agent_runtime` to override which agent runtime the session uses — `claude_code` (Claude Code) or `codex` (OpenAI Codex CLI). Pass `config: { model: "..." }` to choose the model (e.g. `opus`/`sonnet`/`haiku`/`fable` for claude_code, `gpt-5.6-sol`/`gpt-5.6-terra`/`gpt-5.6-luna` for codex). Both are optional: when omitted, resolution falls through the agent root's `default_runtime`/`default_model`, then the global session defaults set on the Settings page, then the hardcoded defaults. Call get_configs to discover each root's defaults and pick a model that is valid for the chosen runtime.

        **Scheduling class:** Pass `scheduling_class: "spot"` for long, unattended work nobody is waiting on, so it yields to work a human is watching when the Claude Code quota gets tight. Omit it and the session takes its parent's explicit class, or its genesis's default.

        **Precedence:** Spot sessions start in precedence order, highest first, on an absolute scale (100000 comes before 50). Omit `precedence` in the ordinary case: a session you spawn is placed one point above the session in `parent_session_id`, which keeps a tree of work together. Set it when this work genuinely outranks — or is genuinely less urgent than — the rest of the spot queue.

        **Retries and timeouts — pass `idempotency_key`:** this create is safe to retry only if you name the attempt. Pass an `idempotency_key` unique to the unit of work; repeating the call with the same key returns the session the first call created and queues no second agent. This matters because the call can fail *after* the session is created: a gateway timeout is returned by the proxy in front of Zimmer, so it carries no session id and cannot tell you whether the write landed — and in every observed case it had. So:

        - **With an `idempotency_key`:** on any error, including a timeout, retry with the same key. You get the existing session back, or a new one if the first call really did not land. That is the guarantee; you do not need to go looking.
        - **Without one:** do NOT retry — a retry duplicates the session, the clone, and the agent's quota slot. Call `quick_search_sessions` with the title you passed and check whether the session already exists.

        **Use cases:**
        - Start a new agent task on a repository
        - Create a session to work on a specific branch
        - Set up an agent with specific MCP servers and skills enabled
        - Create a session with custom metadata for tracking
      DESC

      input_schema({
        type: "object",
        properties: {
          agent_runtime: { type: "string", description: AGENT_RUNTIME_DESC },
          prompt: { type: "string", description: PROMPT_DESC },
          agent_root: { type: "string", description: AGENT_ROOT_DESC },
          title: { type: "string", description: TITLE_DESC },
          slug: { type: "string", description: SLUG_DESC },
          goal: { type: "string", description: GOAL_DESC },
          execution_provider: {
            type: "string",
            enum: Session::EXECUTION_PROVIDERS,
            description: EXECUTION_PROVIDER_DESC
          },
          mcp_servers: { type: "array", items: { type: "string" }, description: MCP_SERVERS_DESC },
          skills: { type: "array", items: { type: "string" }, description: SKILLS_DESC },
          plugins: { type: "array", items: { type: "string" }, description: PLUGINS_DESC },
          hooks: { type: "array", items: { type: "string" }, description: HOOKS_DESC },
          config: { type: "object", description: CONFIG_DESC },
          custom_metadata: { type: "object", description: CUSTOM_METADATA_DESC },
          parent_session_id: { type: "integer", description: PARENT_SESSION_ID_DESC },
          scheduling_class: {
            type: "string",
            enum: SessionGenesis::CLASSES,
            description: SCHEDULING_CLASS_DESC
          },
          precedence: { type: "integer", description: PRECEDENCE_DESC },
          idempotency_key: { type: "string", description: IDEMPOTENCY_KEY_DESC },
          auto_compact_window: { type: "integer", description: AUTO_COMPACT_WINDOW_DESC }
        },
        required: []
      })

      def call(args)
        agent_root_name = args["agent_root"].presence
        # An omitted mcp_servers means "take the root's defaults" (that is what
        # apply_agent_root_defaults! does), so it is only a deviation to check when
        # the caller actually named a list. This gate stays `key?` rather than the
        # `is_a?(Array)` used elsewhere: a restricted connection that sends an
        # explicit null already fails here, and loosening that would widen what a
        # restricted connection may spawn.
        enforce_root_constraints!(agent_root_name, args.key?("mcp_servers") ? string_array(args["mcp_servers"]) : nil)

        # Answered before any of the create work — the retry this exists for is a
        # caller that already got its session and does not know it, so the cheap
        # lookup is the whole response. Placed after the restriction check so a
        # restricted connection cannot use a guessed key as a way around it.
        idempotency_key = args["idempotency_key"].presence
        replayed = Sessions::IdempotentCreate.existing(idempotency_key)
        return format_session(replayed, reused: true) if replayed

        session = Session.new(session_attributes(args))
        # A router spawning downstream work passes parent_session_id, and that
        # session belongs to the same line of work as its parent — assign_genesis
        # inherits it. Only a parentless spawn, which nothing connects to a human,
        # is classified `api`.
        session.genesis = SessionGenesis::API if session.parent_session_id.blank?
        # Recorded before save so the job starting moments later can tell a
        # deliberate "no MCP servers" from a column that landed empty by accident
        # and would otherwise be healed back to the root's defaults.
        session.record_explicit_mcp_servers(session.mcp_servers) if explicit_list?(args, "mcp_servers")
        apply_agent_root_defaults!(session, agent_root_name, args: args, explicit_runtime: args["agent_runtime"].present?) if agent_root_name
        ensure_model!(session)

        # The lookup above answers the sequential retry; this answers the
        # concurrent one, where the first call is still inside its INSERT when
        # the second arrives. Either way a reused result means the agent job was
        # already queued by the call that won, so nothing more happens here —
        # queueing a second one is the duplicate this whole path exists to avoid.
        result = Sessions::IdempotentCreate.save(session, idempotency_key)
        raise ActiveRecord::RecordInvalid, session unless result
        return format_session(result.session, reused: true) if result.reused?

        if session.prompt.present?
          job = AgentSessionJob.enqueue_new_session(session.id)
          session.update(job_id: job.job_id)
        end

        format_session(session)
      rescue AgentRootsConfig::AgentRootNotFoundError => e
        raise ToolError, "Invalid agent_root: #{e.message}"
      end

      private

      # A restricted connection must name an allowed root AND take that root's
      # MCP servers exactly — no additions, no removals.
      #
      # @param requested_servers [Array<String>, nil] nil when the caller omitted
      #   mcp_servers entirely, which resolves to the root's defaults and so can
      #   never deviate from them.
      def enforce_root_constraints!(agent_root_name, requested_servers)
        return unless context.restricted?

        enforce_allowed_root!(agent_root_name)

        root = AgentRootsConfig.find(agent_root_name)
        unless root
          raise ToolError, "Agent root \"#{agent_root_name}\" is in the allowed list but was not found in the configuration. " \
                           "Available agent roots: #{AgentRootsConfig.names.join(', ')}"
        end

        return if requested_servers.nil?

        defaults = root.default_mcp_servers || []
        return if defaults.sort == requested_servers.sort

        raise ToolError, "Agent root \"#{root.name}\" must use its exact default MCP servers. " \
                         "Expected: [#{format_list(defaults)}], but got: [#{format_list(requested_servers)}]. " \
                         "You cannot add or remove MCP servers when this connection is restricted to specific agent roots."
      end

      def session_attributes(args)
        attrs = {}
        attrs[:agent_runtime] = args["agent_runtime"] if args["agent_runtime"].present?
        attrs[:prompt] = args["prompt"] if args["prompt"].present?
        attrs[:title] = args["title"] if args["title"].present?
        attrs[:slug] = args["slug"] if args["slug"].present?
        attrs[:execution_provider] = args["execution_provider"] if args["execution_provider"].present?
        attrs[:auto_compact_window] = args["auto_compact_window"] unless args["auto_compact_window"].nil?
        attrs[:goal] = resolved_goal(args["goal"]) if args["goal"].present?
        # Gate on "the caller named a list", not on "the list has entries" — the
        # same test change_mcp_servers applies (action_session.rb). `[].present?`
        # is false, so a presence gate drops an explicit empty array before it
        # ever reaches the session, and the caller silently gets the root's
        # defaults instead of the none it asked for.
        attrs[:mcp_servers] = string_array(args["mcp_servers"]) if explicit_list?(args, "mcp_servers")
        attrs[:catalog_skills] = string_array(args["skills"]) if explicit_list?(args, "skills")
        attrs[:catalog_plugins] = string_array(args["plugins"]) if explicit_list?(args, "plugins")
        attrs[:catalog_hooks] = string_array(args["hooks"]) if explicit_list?(args, "hooks")
        attrs[:config] = args["config"] if args["config"].is_a?(Hash)
        attrs[:custom_metadata] = args["custom_metadata"] if args["custom_metadata"].is_a?(Hash)
        attrs[:parent_session_id] = args["parent_session_id"] unless args["parent_session_id"].nil?
        attrs[:scheduling_class] = scheduling_class(args) if args["scheduling_class"].present?
        attrs[:precedence] = precedence(args) unless args["precedence"].nil?
        attrs[:idempotency_key] = args["idempotency_key"] if args["idempotency_key"].present?
        attrs
      end

      # An explicit class beats the genesis-derived default and beats a parent's,
      # which is the whole point of the argument: a router working under a `slack`
      # parent can still spawn one long batch as spot without demoting every other
      # session that shares that genesis.
      def scheduling_class(args)
        value = args["scheduling_class"].to_s
        unless SessionGenesis::CLASSES.include?(value)
          raise ToolError, "Unknown scheduling_class: #{value}. Valid: #{SessionGenesis::CLASSES.join(', ')}"
        end

        value
      end

      # An explicit rank beats the "just above the parent" default. Bounded rather
      # than free: the column is a 32-bit integer and the reorder maths averages
      # values, so a caller passing 10**12 would break the ranked view's arithmetic
      # rather than simply ranking very high.
      def precedence(args)
        value = args["precedence"]
        unless value.is_a?(Integer) || value.to_s.match?(/\A-?\d+\z/)
          raise ToolError, "precedence must be an integer (got #{value.inspect})"
        end

        value = value.to_i
        unless value.between?(SessionPrecedence::MIN, SessionPrecedence::MAX)
          raise ToolError, "precedence must be between #{SessionPrecedence::MIN} and #{SessionPrecedence::MAX}"
        end

        value
      end

      # Goals are passed to the agent as prose, so a goal ID is swapped for its
      # description; anything not in the catalog is passed through verbatim.
      def resolved_goal(goal)
        GoalsConfig.find(goal.to_s)&.description || goal
      end

      # @param args [Hash] the raw tool arguments, needed to tell an omitted
      #   artifact list (take the root's defaults) from an explicit `[]` (take none).
      def apply_agent_root_defaults!(session, agent_root_name, args:, explicit_runtime:)
        root = AgentRootsConfig.find!(agent_root_name)

        # The per-spawn override wins; otherwise the session adopts the root's
        # declared runtime rather than the column default.
        session.agent_runtime = root.default_runtime unless explicit_runtime
        session.git_root = root.url if session.git_root.blank?
        session.branch = root.default_branch || "main"
        session.subdirectory = root.subdirectory if session.subdirectory.blank? && root.subdirectory.present?
        # Only an OMITTED list falls back to the root's defaults. A `.blank?` test
        # cannot tell omitted from explicitly-empty, so it overwrites `[]` with
        # the defaults — which is how a caller asking for no MCP servers ends up
        # holding whatever the root declares, SSH access included.
        session.mcp_servers = root.default_mcp_servers || [] unless explicit_list?(args, "mcp_servers")
        session.catalog_skills = root.default_skills || [] unless explicit_list?(args, "skills")
        session.catalog_plugins = root.default_plugins || [] unless explicit_list?(args, "plugins")
        session.catalog_hooks = root.default_hooks || [] unless explicit_list?(args, "hooks")
        session.metadata = (session.metadata || {}).merge("agent_root_key" => agent_root_name)

        return if session.config&.dig("model").present?

        # A root's default_model is typically a claude_code model; applying it to a
        # codex spawn would persist an invalid model, so self-heal to the global
        # default for the resolved runtime.
        model = root.default_model
        model = AppSetting.current.resolved_default_model_for(session.agent_runtime) unless ModelCatalog.valid_model?(session.agent_runtime, model)
        session.config = (session.config || {}).merge("model" => model)
      end

      # The model is always explicit in config so the spawn never depends on a
      # runtime-side default. In practice apply_agent_root_defaults! has already
      # filled it in: this tool has no git_root param, so every spawn it can
      # complete names an agent_root (Session validates git_root presence, and
      # the root is the only thing that supplies it).
      def ensure_model!(session)
        return if session.config&.dig("model").present?

        session.config = (session.config || {}).merge("model" => ModelCatalog.default_for(session.agent_runtime))
      end

      # @param reused [Boolean] true when this call created nothing and is handing
      #   back the session an earlier call with the same idempotency_key made. Said
      #   in the heading rather than a footnote: a caller retrying a timeout is
      #   deciding whether it now has one session or two, and that is the answer.
      def format_session(session, reused: false)
        lines = [
          reused ? "## Existing Session Returned (idempotency_key matched)" : "## Session Started Successfully",
          "",
          "- **ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Status:** #{session.status}"
        ]
        lines << "- **Slug:** #{session.slug}" if session.slug.present?

        if reused
          lines << ""
          lines << "*A session with this `idempotency_key` already existed, so no new session was created " \
                   "and no second agent job was queued. This is the session your earlier call made.*"
          return lines.join("\n")
        end

        if session.job_id.present?
          lines << "- **Job ID:** #{session.job_id}"
          lines << ""
          lines << "*The agent job has been queued and will start shortly.*"
        else
          lines << ""
          lines << '*No prompt was provided. Use action_session with "follow_up" or "restart" action to start the agent.*'
        end

        lines.join("\n")
      end

      def string_array(value)
        Array(value).map(&:to_s)
      end

      # True when the caller actually named this artifact list, empty or not.
      # An array is the only thing that counts as naming one, which is the same
      # test change_mcp_servers uses (action_session.rb) — so launch-time and
      # change-time agree on what an explicit `[]` means.
      def explicit_list?(args, key)
        args[key].is_a?(Array)
      end

      def format_list(list)
        list.empty? ? "(none)" : list.join(", ")
      end
    end
  end
end
