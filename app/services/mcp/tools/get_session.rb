# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors GET /api/v1/sessions/:id, plus (on demand) GET
    # /api/v1/sessions/:id/transcript, .../logs and .../subagent_transcripts.
    #
    # The transcript is *not* inlined by default: a full transcript can be
    # megabytes and would evict the caller's context. Instead the response points
    # at the transcript file on disk so the caller can grep/tail it.
    class GetSession < Tool
      LOG_LEVEL_ICONS = {
        "debug" => "🔍",
        "info" => "ℹ️",
        "warning" => "⚠️",
        "error" => "❌",
        "verbose" => "📝"
      }.freeze

      SUBAGENT_STATUS_ICONS = {
        "running" => "🔄",
        "completed" => "✅",
        "failed" => "❌"
      }.freeze

      # Tool result truncation the REST transcript action applies to tool results.
      TOOL_RESULT_TRUNCATION = 500

      tool_name "get_session"

      description <<~DESC
        Get detailed information about a specific agent session.

        **Returns:** Complete session details including status, configuration, metadata, and optionally:
        - Full session transcript (WARNING: can be very large)
        - Session logs (paginated)
        - Subagent transcripts (paginated)

        **Transcript access:** By default (include_transcript=false), the response includes the transcript file path instead of the full content. You can then efficiently grep, tail, or read specific sections of that file — for example, read the last ~100 lines to see the most recent messages. This avoids overwhelming your context window with massive transcripts.

        **Use cases:**
        - View detailed session information
        - Check session status and progress (use transcript to determine if a "needs_input" session has completed its task or needs follow-up)
        - Retrieve session transcript for review
        - Review logs for debugging
        - Inspect subagent transcripts
      DESC

      input_schema({
        type: "object",
        properties: {
          id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: 'Session ID (numeric) or slug (string). Examples: "1", "fix-auth-bug-20250115"'
          },
          include_transcript: {
            type: "boolean",
            description: "Include the full transcript inline. Default: false. WARNING: can be very large and may overwhelm your context window. When false, the transcript file path is returned instead so you can grep/tail it efficiently (see tool description for tips)."
          },
          transcript_format: {
            type: "string",
            enum: [ "text", "json" ],
            description: 'Format for transcript retrieval: "text" (human-readable) or "json" (structured). Only used when include_transcript is true. When specified, fetches transcript via dedicated endpoint instead of inline.'
          },
          include_logs: {
            type: "boolean",
            description: "Include logs for the session. Default: false. Use logs_page and logs_per_page for pagination."
          },
          logs_page: {
            type: "number",
            minimum: 1,
            description: "Page number for logs pagination. Default: 1"
          },
          logs_per_page: {
            type: "number",
            minimum: 1,
            maximum: 100,
            description: "Number of logs per page (1-100). Default: 25"
          },
          include_subagent_transcripts: {
            type: "boolean",
            description: "Include subagent transcripts for the session. Default: false. Use transcripts_page and transcripts_per_page for pagination."
          },
          transcripts_page: {
            type: "number",
            minimum: 1,
            description: "Page number for subagent transcripts pagination. Default: 1"
          },
          transcripts_per_page: {
            type: "number",
            minimum: 1,
            maximum: 100,
            description: "Number of subagent transcripts per page (1-100). Default: 25"
          }
        },
        required: [ "id" ]
      })

      def call(args)
        session = find_session(args["id"])

        include_transcript = truthy?(args["include_transcript"])
        transcript_format = args["transcript_format"].presence
        # transcript_format routes through the formatted-transcript rendering (the
        # REST transcript action) rather than dumping the raw JSONL inline.
        use_formatted_transcript = include_transcript && transcript_format.present?

        output = format_session_details(session, include_transcript && !use_formatted_transcript, include_transcript)

        if use_formatted_transcript
          output += "\n\n### Transcript"
          output += "\n```"
          output += "\n#{formatted_transcript(session)}"
          output += "\n```"
        end

        output += format_logs(session, args) if truthy?(args["include_logs"])
        output += format_subagent_transcripts(session, args) if truthy?(args["include_subagent_transcripts"])

        output
      end

      private

      # @param inline_transcript [Boolean] render the raw transcript in the body
      # @param include_transcript [Boolean] the caller's flag — suppresses the
      #   file-path hint even when the transcript arrives via the formatted path
      def format_session_details(session, inline_transcript, include_transcript)
        lines = [
          "## Session: #{session.title}",
          "",
          "### Basic Information",
          "- **ID:** #{session.id}",
          "- **Status:** #{session.status}",
          "- **Agent Runtime:** #{session.agent_runtime}"
        ]

        lines << "- **Slug:** #{session.slug}" if session.slug.present?
        lines << "- **Category:** #{session.category.name}" if session.category

        lines << ""
        lines << "### Git Configuration"
        lines << "- **Repository:** #{session.git_root}" if session.git_root.present?
        lines << "- **Branch:** #{session.branch}" if session.branch.present?
        lines << "- **Subdirectory:** #{session.subdirectory}" if session.subdirectory.present?

        lines << ""
        lines << "### Execution"
        lines << "- **Execution Provider:** #{session.execution_provider}"
        lines << "- **Goal:** #{session.goal}" if session.goal.present?
        lines << "- **MCP Servers:** #{session.mcp_servers.join(', ')}" if session.mcp_servers.present?
        lines << "- **Skills:** #{session.catalog_skills.join(', ')}" if session.catalog_skills.present?
        lines << "- **Plugins:** #{session.catalog_plugins.join(', ')}" if session.catalog_plugins.present?

        if session.prompt.present?
          lines << ""
          lines << "### Current Prompt"
          lines << "```"
          lines << session.prompt
          lines << "```"
        end

        lines << ""
        lines << "### Job Information"
        lines << "- **Claude Session ID:** #{session.session_id}" if session.session_id.present?
        lines << "- **Initial Job ID:** #{session.job_id}" if session.job_id.present?
        lines << "- **Running Job ID:** #{session.running_job_id}" if session.running_job_id.present?

        metadata = session.metadata || {}
        if metadata.any?
          lines << ""
          lines << "### System Metadata"
          lines << "```json"
          lines << JSON.pretty_generate(metadata)
          lines << "```"
        end

        custom_metadata = session.custom_metadata || {}
        if custom_metadata.any?
          lines << ""
          lines << "### Custom Metadata"
          lines << "```json"
          lines << JSON.pretty_generate(custom_metadata)
          lines << "```"
        end

        lines << ""
        lines << "### Timestamps"
        lines << "- **Created:** #{session.created_at.iso8601}"
        lines << "- **Updated:** #{session.updated_at.iso8601}"
        lines << "- **Archived:** #{session.archived_at.iso8601}" if session.archived_at

        if inline_transcript && session.transcript.present?
          lines << ""
          lines << "### Transcript"
          lines << "```"
          lines << session.transcript.to_s
          lines << "```"
        end

        # Context safety: without an inline transcript, hand the caller the file so
        # it can tail/grep instead of loading the whole thing.
        if !include_transcript && session.session_id.present?
          lines << ""
          lines << "### Transcript File"
          lines << "- **Path pattern:** `~/.claude/projects/*/#{session.session_id}.jsonl`"
          lines << "- **Find exact path:** `ls ~/.claude/projects/*/#{session.session_id}.jsonl`"
          lines << "- **Tip:** Once you have the exact path, read the last ~100 lines to see the most recent messages, or grep for specific keywords. This avoids loading the entire transcript into your context window."
        end

        lines.join("\n")
      end

      # The plain-text rendering GET /api/v1/sessions/:id/transcript returns. Both
      # "text" and "json" formats carry the same rendered text there; the format
      # only picks the HTTP content type, which has no analogue over MCP.
      def formatted_transcript(session)
        parsed = session.parsed_transcript
        raise ToolError, "No transcript available for this session" if parsed.blank?

        lines = []
        parsed.each do |entry|
          message = entry["message"] || entry
          content = message["content"] || ""

          case entry["type"]
          when "user"
            lines << "--- User ---"
            lines << content
            lines << ""
          when "assistant"
            lines << "--- Assistant ---"
            lines << content
            lines << ""
          when "tool_use"
            lines << "--- Tool Use: #{message['name'] || 'unknown'} ---"
            lines << content.to_s if content.present?
            lines << ""
          when "tool_result"
            lines << "--- Tool Result ---"
            lines << content.to_s.truncate(TOOL_RESULT_TRUNCATION) if content.present?
            lines << ""
          end
        end

        lines.join("\n")
      end

      def format_logs(session, args)
        scope = session.logs.order(created_at: :desc)
        page, per_page = pagination_params(args["logs_page"], args["logs_per_page"])
        total_count = scope.count
        total_pages = (total_count.to_f / per_page).ceil
        logs = scope.limit(per_page).offset((page - 1) * per_page)

        lines = [
          "",
          "---",
          "### Logs (#{total_count} total, page #{page} of #{total_pages})",
          ""
        ]

        if logs.empty?
          lines << "No logs found."
        else
          logs.each do |log|
            icon = LOG_LEVEL_ICONS.fetch(log.level.to_s, "📝")
            lines << "#{icon} **[#{log.level.to_s.upcase}]** #{log.created_at.iso8601}"
            lines << "   #{log.content}"
            lines << ""
          end
        end

        lines << "*More logs available. Use logs_page=#{page + 1} to see the next page.*" if page < total_pages

        lines.join("\n")
      end

      def format_subagent_transcripts(session, args)
        scope = session.subagent_transcripts.order(created_at: :desc)
        page, per_page = pagination_params(args["transcripts_page"], args["transcripts_per_page"])
        total_count = scope.count
        total_pages = (total_count.to_f / per_page).ceil
        transcripts = scope.limit(per_page).offset((page - 1) * per_page)

        lines = [
          "",
          "---",
          "### Subagent Transcripts (#{total_count} total, page #{page} of #{total_pages})",
          ""
        ]

        if transcripts.empty?
          lines << "No subagent transcripts found."
        else
          transcripts.each do |transcript|
            icon = transcript.status.present? ? SUBAGENT_STATUS_ICONS.fetch(transcript.status.to_s, "📝") : "📝"
            label = transcript.display_label.presence || transcript.agent_id
            lines << "#{icon} **#{label}** (#{transcript.status.presence || 'unknown'})"
            lines << "   #{transcript.description}" if transcript.description.present?
            lines << "   Type: #{transcript.subagent_type}" if transcript.subagent_type.present?
            lines << "   Created: #{transcript.created_at.iso8601}"
            lines << ""
          end
        end

        lines << "*More transcripts available. Use transcripts_page=#{page + 1} to see the next page.*" if page < total_pages

        lines.join("\n")
      end

      # Same clamping the REST API's paginate helper applies.
      def pagination_params(page, per_page)
        [
          [ page.to_i.nonzero? || 1, 1 ].max,
          [ [ per_page.to_i.nonzero? || 25, 1 ].max, 100 ].min
        ]
      end

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value) == true
      end
    end
  end
end
