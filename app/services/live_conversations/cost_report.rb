# frozen_string_literal: true

module LiveConversations
  # The LiveUsageEvent ledger rolled up for a window: what each voice mode (an
  # engine with its models) cost, per conversation, per minute of call, per day
  # and per operation, with the speed and failure signals beside the money, so
  # a mode's cost can be weighed against how it performed. Money comes in two
  # figures: `billed_usd` (metered money only) and `list_usd` (everything at
  # list price, which is what a Claude subscription's use would have cost). Behind /live/costs, `GET /api/v1/live/costs` and
  # the `get_live_costs` MCP tool.
  #
  # Grouped sums in SQL; nothing loads the rows. `#events` is the row-level
  # export (the page's CSV and `GET /api/v1/live/usage_events`).
  class CostReport
    DEFAULT_DAYS = 7
    MAX_DAYS = 365
    TOP_CONVERSATIONS = 25
    EXPORT_LIMIT = 10_000

    attr_reader :from, :to, :engine

    def initialize(days: nil, from: nil, to: nil, engine: nil, now: Time.current)
      # Up to the next whole minute, so two requests a second apart agree.
      @to = (to || now).change(sec: 0) + 1.minute
      days = days.to_i.clamp(1, MAX_DAYS) if days.present?
      @from = from || (@to - (days || DEFAULT_DAYS).days)
      @from = [ @from, @to - MAX_DAYS.days ].max
      @engine = engine.presence&.to_s
      raise ArgumentError, "engine must be one of: #{LiveUsageEvent::ENGINES.join(', ')}" if @engine && !LiveUsageEvent::ENGINES.include?(@engine)
    end

    def scope
      rows = LiveUsageEvent.between(@from, @to)
      @engine ? rows.for_engine(@engine) : rows
    end

    def as_api_json
      {
        window: { from: @from.iso8601, to: @to.iso8601, engine: @engine },
        price_version: LiveVoicePricing.version,
        totals: totals,
        by_mode: by_mode,
        by_operation: by_operation,
        by_day: by_day,
        by_conversation: by_conversation,
        caps: caps,
        engines: VoiceEngine.statuses
      }
    end

    def totals
      row = scope.pick(Arel.sql(LiveUsageEvent::BILLED_COST_SQL), Arel.sql("COALESCE(SUM(cost_usd), 0)"), Arel.sql("COUNT(*)"),
                       Arel.sql("COUNT(*) FILTER (WHERE NOT priced)"), Arel.sql("COUNT(DISTINCT live_conversation_id)"))
      { billed_usd: row[0].to_f.round(6), list_usd: row[1].to_f.round(6), events: row[2].to_i, unpriced_events: row[3].to_i, conversations: row[4].to_i }
    end

    # Per mode — an engine with the models it ran on — the experience beside the
    # cost: what was billed and what it was worth at list price, per
    # conversation and per minute of call, time to first audio, the delegation
    # round trip, errors and fallbacks. What decides which mode to keep.
    def by_mode
      scope.group(:engine, :mode).pluck(
        :engine, :mode,
        Arel.sql(LiveUsageEvent::BILLED_COST_SQL),
        Arel.sql("SUM(cost_usd)"),
        # A fallback names the engine that did NOT run, so it is no conversation of that engine's.
        Arel.sql("COUNT(DISTINCT live_conversation_id) FILTER (WHERE operation <> 'engine_fallback')"),
        Arel.sql("SUM(seconds) FILTER (WHERE operation = 'call')"),
        Arel.sql("COUNT(*) FILTER (WHERE operation = 'call')"),
        Arel.sql("COUNT(*) FILTER (WHERE operation = 'delegation')"),
        Arel.sql("COUNT(*) FILTER (WHERE operation = 'tool_call')"),
        Arel.sql("AVG(latency_ms) FILTER (WHERE operation = 'delegation')"),
        Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY first_audio_ms) FILTER (WHERE operation = 'turn_latency' AND first_audio_ms IS NOT NULL)"),
        Arel.sql("PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY first_audio_ms) FILTER (WHERE operation = 'turn_latency' AND first_audio_ms IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE operation = 'turn_latency' AND first_audio_ms IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE error IS NOT NULL AND operation <> 'engine_fallback')"),
        Arel.sql("COUNT(*) FILTER (WHERE operation = 'engine_fallback')")
      ).map do |engine, mode, billed, list, conversations, call_seconds, calls, delegations, tool_calls, delegation_ms, p50, p90, turns, errors, fallbacks|
        minutes = call_seconds.to_f / 60
        {
          engine: engine, mode: mode, billed_usd: billed.to_f.round(6), list_usd: list.to_f.round(6), conversations: conversations.to_i,
          billed_per_conversation_usd: per(billed, conversations.to_i), list_per_conversation_usd: per(list, conversations.to_i),
          calls: calls.to_i, call_minutes: minutes.round(2),
          billed_per_minute_usd: per(billed, minutes), list_per_minute_usd: per(list, minutes),
          delegations: delegations.to_i, tool_calls: tool_calls.to_i, avg_delegation_ms: delegation_ms&.to_f&.round,
          first_audio_ms_p50: p50&.to_f&.round, first_audio_ms_p90: p90&.to_f&.round, timed_turns: turns.to_i,
          errors: errors.to_i, fallbacks: fallbacks.to_i
        }
      end.sort_by { |row| [ row[:engine], -row[:list_usd] ] }
    end

    def by_operation
      scope.group(:engine, :operation, :vendor, :model, :billing_basis).pluck(
        :engine, :operation, :vendor, :model, :billing_basis, Arel.sql("SUM(cost_usd)"), Arel.sql("COUNT(*)"),
        Arel.sql("SUM(input_tokens)"), Arel.sql("SUM(output_tokens)"), Arel.sql("SUM(cache_read_tokens)"), Arel.sql("SUM(cache_write_tokens)"),
        Arel.sql("SUM(audio_input_tokens)"), Arel.sql("SUM(audio_output_tokens)"), Arel.sql("SUM(seconds)"), Arel.sql("AVG(latency_ms)")
      ).map do |engine, operation, vendor, model, basis, cost, events, input, output, cache_read, cache_write, audio_in, audio_out, seconds, latency|
        {
          engine: engine, operation: operation, vendor: vendor, model: model, billing_basis: basis, list_usd: cost.to_f.round(6),
          billed_usd: basis == "metered" ? cost.to_f.round(6) : 0.0, events: events.to_i,
          input_tokens: input.to_i, output_tokens: output.to_i, cache_read_tokens: cache_read.to_i, cache_write_tokens: cache_write.to_i,
          audio_input_tokens: audio_in.to_i, audio_output_tokens: audio_out.to_i, seconds: seconds.to_f.round(1), avg_latency_ms: latency&.to_f&.round
        }
      end.sort_by { |row| -row[:list_usd] }
    end

    def by_day
      day = Arel.sql("DATE(occurred_at AT TIME ZONE 'UTC' AT TIME ZONE #{ActiveRecord::Base.connection.quote(zone_name)})")
      scope.group(day, :engine).order(day).pluck(day, :engine, Arel.sql(LiveUsageEvent::BILLED_COST_SQL), Arel.sql("SUM(cost_usd)"),
                                                Arel.sql("COUNT(DISTINCT live_conversation_id) FILTER (WHERE operation <> 'engine_fallback')"))
           .map { |date, engine, billed, list, conversations| { date: date.to_s, engine: engine, billed_usd: billed.to_f.round(6), list_usd: list.to_f.round(6), conversations: conversations.to_i } }
    end

    def by_conversation
      # A fallback row is the engine that did not run: the conversation is listed under the one that did.
      rows = scope.where.not(live_conversation_id: nil).where.not(operation: "engine_fallback").group(:live_conversation_id, :engine)
                  .order(Arel.sql("SUM(cost_usd) DESC")).limit(TOP_CONVERSATIONS)
                  .pluck(:live_conversation_id, :engine, Arel.sql(LiveUsageEvent::BILLED_COST_SQL), Arel.sql("SUM(cost_usd)"),
                         Arel.sql("COUNT(*) FILTER (WHERE operation = 'delegation')"), Arel.sql("SUM(seconds) FILTER (WHERE operation = 'call')"),
                         Arel.sql("MIN(occurred_at)"), Arel.sql("MAX(occurred_at)"))
      titles = LiveConversation.where(id: rows.map(&:first)).pluck(:id, :title).to_h
      rows.map do |id, engine, billed, list, delegations, call_seconds, first, last|
        { live_conversation_id: id, title: titles[id], engine: engine, billed_usd: billed.to_f.round(6), list_usd: list.to_f.round(6),
          delegations: delegations.to_i, call_minutes: (call_seconds.to_f / 60).round(2), first_at: first&.iso8601, last_at: last&.iso8601 }
      end
    end

    # Today's spend against the caps, per experimental engine.
    def caps
      setting = LiveSetting.current
      (VoiceEngine::KEYS - [ VoiceEngine::DEFAULT ]).map { |key| SpendGuard.check(engine: key, conversation: nil, setting: setting).as_api_json.except(:conversation_spend_usd) }
    end

    def events(limit: EXPORT_LIMIT)
      scope.order(:occurred_at, :id).limit(limit)
    end

    CSV_COLUMNS = %w[id occurred_at live_conversation_id engine mode operation vendor model input_tokens output_tokens cache_read_tokens
                     cache_write_tokens audio_input_tokens audio_output_tokens seconds characters count cost_usd billing_basis priced
                     price_version latency_ms first_audio_ms error].freeze

    # RFC 4180, by hand: the csv gem is not in the bundle.
    def to_csv
      lines = [ CSV_COLUMNS.join(",") ]
      events.each do |row|
        lines << CSV_COLUMNS.map { |column| csv_cell(column == "occurred_at" ? row.occurred_at.iso8601 : row[column]) }.join(",")
      end
      "#{lines.join("\r\n")}\r\n"
    end

    private

    def per(amount, denominator) = denominator.to_f.positive? ? (amount.to_f / denominator).round(6) : nil

    # Quoted where it must be, and a leading = + - @ neutralised: `error` can
    # come from a client, and a spreadsheet would run it as a formula.
    def csv_cell(value)
      text = value.to_s
      text = "'#{text}" if value.is_a?(String) && text.match?(/\A[=+\-@]/)
      text.match?(/[",\r\n]/) ? "\"#{text.gsub('"', '""')}\"" : text
    end

    def zone_name = Time.zone.tzinfo.name
  end
end
