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
        - **Goals**: Available session completion criteria (id, name, description)

        **Use this tool** to get all configuration options before calling start_session.
      DESC

      input_schema({
        type: "object",
        properties: {},
        required: []
      })

      def call(_args)
        lines = []

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
        lines << "- If an **Agent Root** has a `default_subdirectory`, pass it as `subdirectory` in `start_session` — do not set `subdirectory` to arbitrary internal paths"
        lines << "- Pass `default_skills` from **Agent Roots** in the `skills` parameter of `start_session` — sessions won't have skills loaded unless you explicitly pass them"
        lines << "- Use `id` values from **Goals** in `start_session` `goal` parameter"

        lines.join("\n")
      end

      private

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
    end
  end
end
