# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors GET /api/v1/sessions, GET /api/v1/sessions/search and
    # GET /api/v1/sessions/:id: the title-oriented session finder. An `id`
    # short-circuits to a single session; a `query` runs the same ILIKE search the
    # REST search action runs (SessionSearchable); otherwise it lists.
    class QuickSearchSessions < Tool
      include SessionSearchable

      # Prompts are shown as a preview only — the full text lives in get_session.
      MAX_PROMPT_DISPLAY_LENGTH = 100
      MAX_QUERY_LENGTH = 1000

      tool_name "quick_search_sessions"

      description <<~DESC
        Quick title-based search for agent sessions in the Zimmer.

        **Important:** This tool only searches session titles. It is NOT a full-text or semantic search across session contents/transcripts. Use this when you roughly know the session title you're looking for.

        **Use cases:**
        - Find a specific session by ID (set id parameter)
        - Search sessions by title keyword (set query parameter)
        - List all sessions with optional status filter
        - Monitor sessions that have completed or need attention (status: "needs_input")

        **Returns:** A list of matching sessions with their status, configuration, and metadata.

        **Session statuses:**
        - waiting: Session created, waiting to start
        - running: Agent is actively executing
        - needs_input: Agent has completed its current work and is idle. May indicate the task is done (most common) or that the agent needs additional input to continue. Check the session transcript to determine which case applies.
        - failed: Session encountered an error
        - archived: Session completed and archived
      DESC

      input_schema({
        type: "object",
        properties: {
          id: {
            type: "number",
            description: "Get a specific session by ID. When provided, other filters are ignored."
          },
          query: {
            type: "string",
            maxLength: MAX_QUERY_LENGTH,
            description: "Search query to find sessions. Matches against session title only — this is a simple title search, not a full-text or semantic search. Leave empty to list all sessions."
          },
          status: {
            type: "string",
            enum: [ "waiting", "running", "needs_input", "failed", "archived" ],
            description: 'Filter results by status. Options: "waiting", "running", "needs_input", "failed", "archived"'
          },
          agent_runtime: {
            type: "string",
            description: "Filter results by agent runtime."
          },
          show_archived: {
            type: "boolean",
            description: "Include archived sessions in results. Default: false"
          },
          page: {
            type: "number",
            minimum: 1,
            description: "Page number for pagination. Default: 1"
          },
          per_page: {
            type: "number",
            minimum: 1,
            maximum: 100,
            description: "Number of results per page (1-100). Default: 25"
          }
        },
        required: []
      })

      def call(args)
        return "## Session Found\n\n#{format_session(find_session(args['id']))}" unless args["id"].nil?

        scope = filtered_scope(args)
        page, per_page = pagination_params(args)
        total_count = scope.count
        total_pages = (total_count.to_f / per_page).ceil
        sessions = scope.limit(per_page).offset((page - 1) * per_page)

        return "No sessions found matching the specified criteria." if sessions.empty?

        lines = [
          "## Agent Sessions",
          "",
          "Found #{total_count} session(s) (page #{page} of #{total_pages}):",
          ""
        ]

        sessions.each do |session|
          lines << format_session(session)
          lines << ""
        end

        if page < total_pages
          lines << "---"
          lines << "*More sessions available. Use page=#{page + 1} to see the next page.*"
        end

        lines.join("\n")
      end

      private

      def filtered_scope(args)
        scope = Session.includes(:category).order(created_at: :desc)

        status = args["status"].presence
        if status
          unless Session.statuses.key?(status.to_s)
            raise ToolError, "Invalid status: #{status}. Valid statuses: #{Session.statuses.keys.join(', ')}"
          end
          scope = scope.where(status: status)
        end

        scope = scope.where(agent_runtime: args["agent_runtime"]) if args["agent_runtime"].present?
        scope = scope.where.not(status: :archived) unless truthy?(args["show_archived"])

        query = args["query"].to_s.strip
        if query.present?
          raise ToolError, "Query too long: maximum query length is #{MAX_QUERY_LENGTH} characters" if query.length > MAX_QUERY_LENGTH
          scope = filter_sessions_by_search(scope, query)
        end

        scope
      end

      # Same clamping the REST API's paginate helper applies.
      def pagination_params(args)
        page = [ args["page"].to_i.nonzero? || 1, 1 ].max
        per_page = [ [ args["per_page"].to_i.nonzero? || 25, 1 ].max, 100 ].min
        [ page, per_page ]
      end

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value) == true
      end

      def format_session(session)
        lines = [
          "### #{session.title} (ID: #{session.id})",
          "",
          "- **Status:** #{session.status}",
          "- **Agent Runtime:** #{session.agent_runtime}"
        ]

        lines << "- **Slug:** #{session.slug}" if session.slug.present?
        lines << "- **Category:** #{session.category.name}" if session.category
        lines << "- **Repository:** #{session.git_root}" if session.git_root.present?
        lines << "- **Branch:** #{session.branch}" if session.branch.present?
        lines << "- **Prompt:** #{truncate_prompt(session.prompt)}" if session.prompt.present?
        lines << "- **MCP Servers:** #{session.mcp_servers.join(', ')}" if session.mcp_servers.present?
        lines << "- **Created:** #{session.created_at.iso8601}"
        lines << "- **Updated:** #{session.updated_at.iso8601}"

        lines.join("\n")
      end

      def truncate_prompt(prompt)
        return prompt if prompt.length <= MAX_PROMPT_DISPLAY_LENGTH
        "#{prompt[0, MAX_PROMPT_DISPLAY_LENGTH]}..."
      end
    end
  end
end
