# frozen_string_literal: true

module Mcp
  module Tools
    # The read side of TestflightFeedbackPollJob: what TestFlight testers sent
    # from the Zimmer iOS app, crash logs included, as App Store Connect gave it.
    #
    # In `health` beside get_system_health: it is a diagnostic read about the
    # deployment's own app, and `health_readonly` puts it on `zimmer-fleet` as
    # well as the unscoped `zimmer` server without adding a server to the catalog.
    class GetTestflightCrashes < Tool
      DEFAULT_LIMIT = 10
      MAX_LIMIT = 50
      DEFAULT_MAX_CHARS = 40_000
      MAX_MAX_CHARS = 100_000
      COMMENT_PREVIEW_CHARS = 200

      tool_name "get_testflight_crashes"

      description <<~DESC
        Read TestFlight feedback for the Zimmer iOS app — crash reports with their full crash logs, and
        screenshot feedback — pulled from App Store Connect every 15 minutes.

        **Modes:**
        - **List** (no `id`): the newest submissions, newest first, one line each: submission id, when,
          build number, device, OS, the crash's headline (exception type, termination reason, crashed
          thread) and the start of the tester's comment. Also says whether the App Store Connect key is
          configured, so an empty list can be told apart from a poller that is not running.
        - **Get** (`id`): one submission in full — every attribute App Store Connect returned, the
          tester's comment, and the crash log text. Crash logs are long: `offset` and `max_chars` page
          through one, and the result says which call returns the rest.

        Crash logs are as App Store Connect returns them (Apple's crash report text, usually
        symbolicated for TestFlight builds). A crash whose log App Store Connect has not produced yet is
        listed with `log pending` and retried by the poller for 7 days.
      DESC

      input_schema({
        type: "object",
        properties: {
          id: { type: "string", description: "An App Store Connect submission id from the list. Returns that submission in full." },
          kind: {
            type: "string",
            enum: %w[crash screenshot all],
            description: "List mode: which submissions. Default: crash"
          },
          limit: { type: "number", minimum: 1, maximum: MAX_LIMIT, description: "List mode: how many. Default: #{DEFAULT_LIMIT}" },
          offset: { type: "number", minimum: 0, description: "Get mode: the crash-log character to start at. Default: 0" },
          max_chars: {
            type: "number",
            minimum: 1_000,
            maximum: MAX_MAX_CHARS,
            description: "Get mode: how many crash-log characters to return. Default: #{DEFAULT_MAX_CHARS}"
          }
        },
        required: []
      })

      def call(args)
        args["id"].present? ? show(args) : list(args)
      end

      private

      def list(args)
        kind = args["kind"].presence || "crash"
        limit = (args["limit"].to_i.nonzero? || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
        scope = TestflightFeedback.newest_first
        scope = scope.where(kind: kind) unless kind == "all"
        rows = scope.limit(limit).to_a

        lines = [ "## TestFlight feedback (#{kind}, newest #{rows.size} of #{scope.count})", "", configuration_line, "" ]
        if rows.empty?
          lines << "No submissions stored."
        else
          rows.each { |row| lines << list_line(row) }
          lines << ""
          lines << "Read one in full, crash log included: `get_testflight_crashes` with `id`."
        end
        lines.join("\n")
      end

      def list_line(row)
        parts = [ "- **#{row.asc_id}** #{row.kind}", row.submitted_at&.iso8601, "build #{row.build_number || '?'}",
          row.device_model, row.os_version ].compact
        if row.crash?
          parts << (row.crash_log ? (row.headline || "#{row.crash_log.length} chars") : "log pending")
        end
        parts << "“#{TextBudget.hard_truncate(row.comment.squish, COMMENT_PREVIEW_CHARS)}”" if row.comment.present?
        parts.join(" · ")
      end

      def show(args)
        row = TestflightFeedback.find_by(asc_id: args["id"].to_s)
        raise ToolError, "No TestFlight submission #{args['id']}. List them with get_testflight_crashes and no id." unless row

        lines = [ "## TestFlight #{row.kind} #{row.asc_id}", "" ]
        lines << "- **Submitted:** #{row.submitted_at&.iso8601 || 'unknown'}"
        lines << "- **Build:** #{row.build_number || 'unknown'}"
        lines << "- **Device:** #{row.device_model || 'unknown'} · #{row.os_version || 'unknown'}"
        lines << "- **Tester:** #{row.tester_email}" if row.tester_email.present?
        lines << "- **Headline:** #{row.headline}" if row.headline
        lines << "" << "### Comment" << "" << (row.comment.presence || "_none_")
        lines << "" << "### Attributes" << "" << "```json" << JSON.pretty_generate(row.raw_attributes.except("comment", "email")) << "```"
        lines.concat(crash_log_section(row, args)) if row.crash?
        lines.join("\n")
      end

      def crash_log_section(row, args)
        return [ "", "### Crash log", "", "_Not fetched yet — App Store Connect has not produced it. The poller retries for 7 days._" ] if row.crash_log.nil?

        text = row.crash_log
        offset = [ args["offset"].to_i, 0 ].max
        max_chars = (args["max_chars"].to_i.nonzero? || DEFAULT_MAX_CHARS).clamp(1_000, MAX_MAX_CHARS)
        slice = text[offset, max_chars].to_s
        shown_end = offset + slice.length

        section = [ "", "### Crash log (characters #{offset}–#{shown_end} of #{text.length})", "", "```", slice, "```" ]
        if shown_end < text.length
          section << TextBudget.truncation_note(shown: slice.length, total: text.length,
            restore: "Call again with `id: \"#{row.asc_id}\", offset: #{shown_end}` for the rest.")
        end
        section
      end

      def configuration_line
        missing = AppStoreConnect::Client::VARIABLES.reject { |name| SecretPresence.for(name).present? }
        if missing.empty?
          newest = TestflightFeedback.maximum(:created_at)
          "Poller: configured; newest row stored #{newest&.iso8601 || 'never'}."
        else
          "Poller: **not configured** — #{missing.join(', ')} unset, so nothing new is being collected."
        end
      end
    end
  end
end
