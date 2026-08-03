# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors GET /api/v1/configs: the static catalog an agent needs before it can
    # call start_session. Agent roots are filtered to the connection's allowed
    # roots so a restricted connection cannot even see roots it may not spawn.
    class GetConfigs < Tool
      tool_name "get_configs"

      description <<~DESC
        Fetches all static configuration data in a single call.

        Returns:
        - **MCP servers**: Available servers for use with start_session (name, title, description)
        - **Agent roots**: Preconfigured repository settings with defaults (git_root, branch, mcp_servers, skills, goal)
        - **Runtime models**: Selectable models grouped by agent runtime, including default and auth requirements
        - **Goals**: Available session completion criteria (id, name, description)

        **Use this tool** to get all configuration options before calling start_session.
      DESC

      input_schema({
        type: "object",
        properties: {},
        required: []
      })

      def call(_args)
        lines = catalog_health_lines

        servers = ServersConfig.all
        lines << "## MCP Servers" << ""
        if servers.empty?
          lines << "*No MCP servers available.*"
        else
          lines << "Found #{servers.size} server#{'s' unless servers.size == 1}:" << ""
          servers.each do |server|
            lines << "### #{server.title}"
            lines << "- **Name:** `#{server.name}`"
            lines << "- **Description:** #{server.description}"
            lines << ""
          end
        end

        roots = allowed_roots
        lines << "---" << "" << "## Agent Roots" << ""
        if roots.empty?
          lines << "*No agent roots configured.*"
        else
          lines << "Found #{roots.size} preconfigured #{roots.size == 1 ? 'repository' : 'repositories'}:" << ""
          roots.each { |root| lines.concat(format_root(root)) }
        end

        lines << "---" << "" << "## Runtime Models" << ""
        ModelCatalog::MODELS.each_key do |runtime|
          lines << "### #{RuntimeRegistry.label_for(runtime)}"
          lines << "- **Runtime:** `#{runtime}`"
          lines << "- **Default Model:** `#{ModelCatalog.default_for(runtime)}`"
          lines << "- **Models:** #{format_models(runtime)}"
          lines << ""
        end

        goals = GoalsConfig.all
        lines << "---" << "" << "## Goals" << ""
        if goals.empty?
          lines << "*No goals defined.*"
        else
          lines << "Found #{goals.size} goal#{'s' unless goals.size == 1}:" << ""
          goals.each do |goal|
            data = goal.to_h.with_indifferent_access
            lines << "### #{data[:name]}"
            lines << "- **ID:** `#{data[:id]}`"
            lines << "- **Description:** #{data[:description]}"
            lines << ""
          end
        end

        lines << "---" << "" << "### Usage Notes" << ""
        lines << "- Use `name` values from **MCP Servers** in `start_session` `mcp_servers` parameter"
        lines << "- Use `git_root` from **Agent Roots** to start sessions with preconfigured defaults"
        lines << "- Use **Runtime Models** to choose a `config.model` value that belongs to the selected `agent_runtime`"
        lines << "- If an **Agent Root** has a `default_subdirectory`, pass it as `subdirectory` in `start_session` — do not set `subdirectory` to arbitrary internal paths"
        lines << "- Pass `default_skills` from **Agent Roots** in the `skills` parameter of `start_session` — sessions won't have skills loaded unless you explicitly pass them"
        lines << "- Use `id` values from **Goals** in `start_session` `goal` parameter"

        lines.join("\n")
      end

      private

      # Prepended when catalog resolution failed, so an agent can tell a broken
      # catalog from an empty one before it acts on the lists below. Without it,
      # `ServersConfig.all` and `allowed_roots` rescue CatalogError to `[]` and
      # this tool reports "No MCP servers available" — indistinguishable from a
      # fresh install, which is #112's defect on the agent side of the wall.
      #
      # Deliberately narrower than the operator-facing banner on the session
      # form. The banner prints `air resolve`'s stderr verbatim; that process is
      # given AIR_GITHUB_TOKEN by AirPrepareService#air_env, so its output is not
      # something to echo onto an agent channel. What an agent needs in order not
      # to act wrongly is the fact and its age, not the text. Same fact,
      # different fidelity, different audience.
      def catalog_health_lines
        failure = AirCatalogService.resolve_failure
        return [] unless failure

        lines = [ "## ⚠️ Catalog resolution is failing", "" ]
        if AirCatalogService.degraded?
          stamp = AirCatalogService.last_known_good_at
          lines << "The lists below come from the last catalog that resolved successfully" \
                   "#{" (#{stamp.utc.iso8601})" if stamp}, not from the current one. Anything added or " \
                   "changed since then is missing here."
        else
          lines << "Resolution failed with no previously cached catalog to fall back on, so the lists " \
                   "below are empty **because of the failure**, not because nothing is configured. Do " \
                   "not read an empty list as an empty catalog, and expect `start_session` to fail " \
                   "until resolution is repaired."
        end
        lines << ""
        lines << "Reported at #{failure[:at].utc.iso8601}. The underlying `air resolve` error is on the " \
                 "session form and in the application logs."
        lines << "" << "---" << ""
      end

      def allowed_roots
        roots = AgentRootsConfig.all
        return roots unless context.restricted?
        roots.select { |root| context.allowed_agent_roots.include?(root.name) }
      end

      def format_root(root)
        data = root.to_h.with_indifferent_access
        lines = [ "### #{data[:title]}" ]
        lines << "- **Name:** `#{data[:name]}`"
        lines << "- **Git Root:** `#{data[:git_root]}`"
        lines << "- **Description:** #{data[:description]}"
        lines << "- **Default Branch:** `#{data[:default_branch]}`" if data[:default_branch].present?
        lines << "- **Default Subdirectory:** `#{data[:default_subdirectory]}`" if data[:default_subdirectory].present?
        if data[:default_mcp_servers].present?
          lines << "- **Default MCP Servers:** #{data[:default_mcp_servers].map { |s| "`#{s}`" }.join(', ')}"
        end
        lines << "- **Default Goal:** `#{data[:default_goal]}`" if data[:default_goal].present?
        if data[:default_skills].present?
          lines << "- **Default Skills:** #{data[:default_skills].map { |s| "`#{s}`" }.join(', ')}"
        end
        lines << "- **Default Model:** `#{data[:default_model]}`" if data[:default_model].present?
        lines << ""
        lines
      end

      def format_models(runtime)
        ModelCatalog.models_for(runtime).map do |model|
          notes = []
          notes << "default" if model[:default]
          notes << "requires OAuth" if model[:requires_oauth]
          "`#{model[:id]}`#{notes.any? ? " (#{notes.join(', ')})" : ""}"
        end.join(", ")
      end
    end
  end
end
