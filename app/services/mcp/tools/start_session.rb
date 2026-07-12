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
        Per-spawn agent runtime override. Valid values are "claude_code" (Claude Code) and "codex" (OpenAI Codex CLI). When omitted, the session adopts the agent_root's default_runtime, falling back to "claude_code". Call get_configs to see each agent root's default_runtime. Pair with `config.model` to pick a model valid for the chosen runtime (e.g. "opus"/"sonnet"/"haiku" for claude_code, "gpt-5.5"/"gpt-5.4" for codex).
      TEXT

      PROMPT_DESC = "Initial prompt for the agent. If provided, the agent job is automatically queued. Omit for a clone-only session."

      AGENT_ROOT_DESC = "Agent root name from get_configs. The API resolves git_root, branch, subdirectory, default_model, and other defaults from the agent root configuration. Always pass this so the session inherits the correct repository, model, and settings."

      TITLE_DESC = <<~TEXT.strip
        STRONGLY RECOMMENDED: Always set a title — treat it as effectively required. The title appears in the Zimmer web UI and push notifications, making sessions identifiable at a glance. Compose a short, descriptive title (under 70 characters) that captures what the session is doing (e.g. "Fix login redirect loop on mobile Safari", "Add dark mode toggle to settings page"). Only omit if you truly have zero context about the session purpose, which should be extremely rare.
      TEXT

      SLUG_DESC = "URL-friendly identifier for the session. Must be unique."

      GOAL_DESC = 'Goal ID from get_configs (e.g. "pr_merged"). The description is automatically resolved and passed to the agent as context.'

      EXECUTION_PROVIDER_DESC = 'Execution environment. Options: "local_filesystem" (runs locally), "remote_sandbox" (runs in isolated sandbox). Default: "local_filesystem"'

      MCP_SERVERS_DESC = 'List of MCP server names to enable for this session. Example: ["github-development", "slack"]'

      SKILLS_DESC = 'List of skill names to enable for this session. Always include the agent root\'s default_skills from get_configs as the starting point — omitting skills means the session gets none. Add extras as needed; removing a default should be rare and intentional. Example: ["discovery-classify", "publish-and-pr"]'

      PLUGINS_DESC = 'List of plugin names to enable for this session. Plugins extend agent capabilities with additional integrations. Example: ["my-plugin"]'

      CONFIG_DESC = <<~TEXT.strip
        Additional configuration as a JSON object. Use `config.model` to choose the agent model for this session (e.g. {"model": "gpt-5.4"} for a codex runtime, or {"model": "sonnet"} for claude_code). The model must be valid for the resolved agent_runtime; call get_configs to see each agent root's default_model. When omitted, the session uses the agent root's default_model (or the runtime's default model). An explicit config.model always takes precedence over the agent root's default_model.
      TEXT

      CUSTOM_METADATA_DESC = "User-defined metadata as a JSON object. Useful for tracking tickets, projects, etc."

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

        **Defaults from Agent Roots:** The agent root defines `default_mcp_servers`, `default_skills`, and optionally a `default_goal`. Omitting `mcp_servers` or `skills` means the session gets NONE — there is no automatic fallback to defaults.

        - **MCP servers:** Start with `default_mcp_servers`. Drop servers the task doesn't need (least-privilege). Add extras when the task requires tools beyond the defaults. When this connection is restricted to specific agent roots, you cannot add servers beyond the defaults.
        - **Skills:** Start with `default_skills`. You can freely add skills beyond the defaults. Removing a default skill should be rare and intentional — only when you have a specific reason, like replacing a skill with a more capable variant that covers the same ground. Skills are lightweight text files with no blast radius, so keeping all defaults costs nothing.

        **Runtime and model selection:** Pass `agent_runtime` to override which agent runtime the session uses — `claude_code` (Claude Code) or `codex` (OpenAI Codex CLI). Pass `config: { model: "..." }` to choose the model (e.g. `opus`/`sonnet`/`haiku` for claude_code, `gpt-5.5`/`gpt-5.4` for codex). Both are optional: when omitted, the session inherits the agent root's `default_runtime` and `default_model`. Call get_configs to discover each root's defaults and pick a model that is valid for the chosen runtime.

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
            enum: [ "local_filesystem", "remote_sandbox" ],
            description: EXECUTION_PROVIDER_DESC
          },
          mcp_servers: { type: "array", items: { type: "string" }, description: MCP_SERVERS_DESC },
          skills: { type: "array", items: { type: "string" }, description: SKILLS_DESC },
          plugins: { type: "array", items: { type: "string" }, description: PLUGINS_DESC },
          config: { type: "object", description: CONFIG_DESC },
          custom_metadata: { type: "object", description: CUSTOM_METADATA_DESC },
          auto_compact_window: { type: "integer", description: AUTO_COMPACT_WINDOW_DESC }
        },
        required: []
      })

      def call(args)
        agent_root_name = args["agent_root"].presence
        # An omitted mcp_servers means "take the root's defaults" (that is what
        # apply_agent_root_defaults! does), so it is only a deviation to check when
        # the caller actually named a list.
        enforce_root_constraints!(agent_root_name, args.key?("mcp_servers") ? string_array(args["mcp_servers"]) : nil)

        session = Session.new(session_attributes(args))
        apply_agent_root_defaults!(session, agent_root_name, explicit_runtime: args["agent_runtime"].present?) if agent_root_name
        ensure_model!(session)
        session.save!

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
        attrs[:mcp_servers] = string_array(args["mcp_servers"]) if args["mcp_servers"].present?
        attrs[:catalog_skills] = string_array(args["skills"]) if args["skills"].present?
        attrs[:catalog_plugins] = string_array(args["plugins"]) if args["plugins"].present?
        attrs[:config] = args["config"] if args["config"].is_a?(Hash)
        attrs[:custom_metadata] = args["custom_metadata"] if args["custom_metadata"].is_a?(Hash)
        attrs
      end

      # Goals are passed to the agent as prose, so a goal ID is swapped for its
      # description; anything not in the catalog is passed through verbatim.
      def resolved_goal(goal)
        GoalsConfig.find(goal.to_s)&.description || goal
      end

      def apply_agent_root_defaults!(session, agent_root_name, explicit_runtime:)
        root = AgentRootsConfig.find!(agent_root_name)

        # The per-spawn override wins; otherwise the session adopts the root's
        # declared runtime rather than the column default.
        session.agent_runtime = root.default_runtime unless explicit_runtime
        session.git_root = root.url if session.git_root.blank?
        session.branch = root.default_branch || "main"
        session.subdirectory = root.subdirectory if session.subdirectory.blank? && root.subdirectory.present?
        session.mcp_servers = root.default_mcp_servers || [] if session.mcp_servers.blank?
        session.catalog_skills = root.default_skills || [] if session.catalog_skills.blank?
        session.catalog_hooks = root.default_hooks || [] if session.catalog_hooks.blank?
        session.catalog_plugins = root.default_plugins || [] if session.catalog_plugins.blank?
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
      # runtime-side default.
      def ensure_model!(session)
        return if session.config&.dig("model").present?

        session.config = (session.config || {}).merge("model" => ModelCatalog.default_for(session.agent_runtime))
      end

      def format_session(session)
        lines = [
          "## Session Started Successfully",
          "",
          "- **ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Status:** #{session.status}"
        ]
        lines << "- **Slug:** #{session.slug}" if session.slug.present?

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

      def format_list(list)
        list.empty? ? "(none)" : list.join(", ")
      end
    end
  end
end
