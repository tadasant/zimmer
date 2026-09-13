# frozen_string_literal: true

module Sessions
  # The one implementation of "re-read this session's transcript off disk and store
  # it" — the manual refresh.
  #
  # It is reachable from six doors, three surfaces each in a single and a bulk form:
  # the web UI's per-session refresh and "Refresh all", `POST /api/v1/sessions/:id/refresh`
  # and `/sessions/refresh_all`, and MCP `action_session`'s `refresh` and
  # `refresh_all`. Until this class existed each door carried its own copy of the
  # sequence — locate the directory, locate the file, read through the redacting
  # source, splice a re-keyed branch, refuse a regression, write, log — and the
  # copies had drifted in the way copies do: the REST API's bulk sweep never went
  # through `RekeyedTranscriptBranch`, so on the one door the #1047 fix did not reach,
  # a longer re-keyed branch still overwrote the abandoned file's tail; and only the
  # web copies retried the write on a dropped database connection. This is the
  # transcript-refresh slice of [#321](https://github.com/tadasant/zimmer/issues/321).
  #
  # Everything that is the *operation* lives here. Each surface keeps only its own
  # way of rendering the outcome — a flash, a JSON body or a `ToolError` — and its
  # own rescue for anything unexpected, because those three already disagree on
  # purpose about what an unexpected error looks like.
  #
  #   Sessions::RefreshTranscript.call(session, actor: :web)                               # one session
  #   Sessions::RefreshTranscript.call(session, actor: :mcp, bulk: true, skip_unchanged: true)  # a sweep
  #
  # ## `skip_unchanged` is a caller's choice, deliberately
  #
  # The REST and MCP sweeps skip a session whose file is byte-identical to what is
  # stored — no write, no log row, not counted as refreshed (#80) — so that calling
  # them repeatedly does not append a row to every session's timeline. The single
  # refreshes and the web sweep write regardless: a refresh somebody asked for by name
  # re-stamps `broadcast_message_count`, which is the repair a stuck timeline wants.
  # The web sweep's disagreement with its REST and MCP twins predates this class and is
  # kept as it was rather than settled silently here.
  class RefreshTranscript
    include DatabaseRetry

    # `refreshed`               - the transcript was written
    # `no_transcript_directory` - the session has no working directory to look in yet
    # `no_transcript_file`      - there is a directory, but no main transcript in it
    # `unchanged`               - identical to what is stored (only with skip_unchanged)
    # `regression`              - shorter than what is stored; the stored copy was kept
    # `database_unavailable`    - the write kept failing on a dropped connection
    Result = Struct.new(:outcome, :message_count, :error, keyword_init: true) do
      def refreshed? = outcome == :refreshed
      def database_unavailable? = outcome == :database_unavailable
    end

    # What the session's timeline row says the refresh came through. These are the
    # strings each door always wrote; they are part of the timeline people read.
    TIMELINE_SOURCES = {
      [ :web, false ] => "manually from filesystem",
      [ :web, true ] => "via bulk refresh",
      [ :api, false ] => "via API",
      [ :api, true ] => "via API bulk refresh",
      [ :mcp, false ] => "via MCP",
      [ :mcp, true ] => "via MCP bulk refresh"
    }.freeze

    # How each surface names itself in Zimmer's own log.
    ACTOR_LABELS = { web: "the web UI", api: "the REST API", mcp: "MCP" }.freeze

    DATABASE_UNAVAILABLE_MESSAGE =
      "The operation couldn't be completed due to high server activity. Please try again."

    # @param session [Session]
    # @param actor [Symbol] :web, :api or :mcp
    # @param bulk [Boolean] whether a sweep asked, which only changes the timeline row
    # @param skip_unchanged [Boolean] leave a byte-identical transcript alone
    # @return [Result]
    def self.call(session, actor:, bulk: false, skip_unchanged: false)
      new(session, actor: actor, bulk: bulk, skip_unchanged: skip_unchanged).call
    end

    def initialize(session, actor:, bulk: false, skip_unchanged: false)
      @session = session
      @actor = actor.to_sym
      @bulk = bulk
      @skip_unchanged = skip_unchanged
      @timeline_source = TIMELINE_SOURCES.fetch([ @actor, @bulk ])
    end

    def call
      directory = transcript_directory
      return Result.new(outcome: :no_transcript_directory) if directory.nil?

      file = Dir.exist?(directory) ? main_transcript_file(directory) : nil
      return Result.new(outcome: :no_transcript_file) unless file

      # Through the runtime's TranscriptSource, not File.read: that is where
      # TranscriptRedactor runs, so a manual refresh cannot write an unredacted
      # transcript over the redacted one the poller stored. It also decompresses a
      # Codex .zst rollout, which a raw read would have stored as binary.
      # RekeyedTranscriptBranch is what makes that read safe when the locator hands
      # back a transcript this conversation was re-keyed into: such a file is NOT a
      # superset of the stored one, and the line-count guard below would wave a
      # longer branch through and take the abandoned file's tail with it (#1047).
      # A no-op on every other file.
      content = RekeyedTranscriptBranch.continue(
        session: @session,
        transcript_path: file,
        content: TranscriptRuntime.source_for(@session).read(file)
      )

      # After the splice, so it compares what would actually be written. It compares
      # against the poller's redacted copy, which is the other reason the read above
      # has to redact: a raw read would never compare equal once a redaction had
      # fired, and the two writers would overwrite each other on every pass.
      return Result.new(outcome: :unchanged) if @skip_unchanged && @session.transcript_matches?(content)

      message_count = count_messages(content)

      # Never let a refresh shrink the stored transcript. A shorter filesystem
      # transcript means the clone was recreated at a new path and started a fresh
      # file; session.transcript is the only durable record, so overwriting it
      # would destroy history. Keep the longer stored copy.
      if @session.transcript_regression?(content)
        Rails.logger.warn(
          "[Sessions::RefreshTranscript] Refused transcript regression for session #{@session.id} " \
          "(stored #{@session.transcript_line_count} events, filesystem #{message_count}, " \
          "requested through #{ACTOR_LABELS.fetch(@actor)}); preserving stored transcript"
        )
        return Result.new(outcome: :regression, message_count: message_count)
      end

      # `base_delay` is the controller helper's: every door is request/response, so
      # somebody is waiting. `DatabaseRetry` rather than `ControllerDatabaseRetry`
      # because its give-up path re-raises instead of rendering — a service hands the
      # surface a result to render.
      with_db_retry(base_delay: 0.3) do
        # broadcast_message_count alongside the transcript, so the next
        # TranscriptPollerJob pass does not re-broadcast messages already shown.
        @session.merge_metadata!("broadcast_message_count" => message_count)
        @session.update!(transcript: content)

        @session.logs.create!(
          content: "Transcript refreshed #{@timeline_source} (#{message_count} messages)",
          level: "info"
        )
      end

      Result.new(outcome: :refreshed, message_count: message_count)
    rescue *DatabaseRetry::RETRYABLE_EXCEPTIONS => e
      Rails.logger.error(
        "[Sessions::RefreshTranscript] database unavailable for session #{@session.id}: #{e.message}"
      )
      Result.new(outcome: :database_unavailable, error: DATABASE_UNAVAILABLE_MESSAGE)
    end

    private

    # The directory holding this session's transcript files, from the session's
    # runtime TranscriptSource — the single place that knows where a runtime writes
    # its transcript. Session#working_directory prefers the recorded
    # working_directory (which includes the agent root subdirectory) and falls back
    # to clone_path for sessions recorded before that key existed.
    #
    # @return [String, nil] nil when the session has no directory yet, or when the
    #   runtime source cannot determine one
    def transcript_directory
      working_directory = @session.working_directory
      return nil unless working_directory.is_a?(String) && working_directory.present?

      TranscriptRuntime.source_for(@session).transcript_directory(working_directory: working_directory)
    rescue StandardError => e
      Rails.logger.error "[Sessions::RefreshTranscript] Failed to get transcript directory: #{e.message}"
      nil
    end

    # The main transcript file inside that directory — also the runtime's own
    # answer. Claude picks <session_id>.jsonl out of a flat directory, Codex globs a
    # date-partitioned tree for the rollout carrying the session's UUID; pairing one
    # runtime's directory with another's file-picker finds nothing at best and
    # someone else's conversation at worst.
    def main_transcript_file(directory)
      TranscriptRuntime.source_for(@session)
        .find_main_transcript(transcript_directory: directory, session: @session)
    end

    # One per line that parses as JSON — what broadcast_message_count counts.
    def count_messages(content)
      return 0 if content.blank?

      content.lines.count do |line|
        line.strip.present? && JSON.parse(line.strip)
      rescue JSON::ParserError
        false
      end
    end
  end
end
