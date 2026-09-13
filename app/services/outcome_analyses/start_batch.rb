# frozen_string_literal: true

module OutcomeAnalyses
  # Create an "Analyze All" batch from the ledger's current filter set.
  #
  # The membership is frozen at creation time: the sessions that matched the
  # filters when the button was clicked are the sessions the batch will analyze,
  # even if new ones archive while it runs. A batch that silently grew would have
  # no honest completion point.
  #
  # Two callers, two contracts. The web UI's Analyze All button honors whatever
  # concurrency a human types. A batch started over MCP (`started_via: "mcp"`) is
  # held to OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY, to one running MCP batch
  # at a time, and to no new one while a stopped one's analyses are in flight.
  # The Outcomes feature's premise is that nothing is analyzed implicitly, and an
  # agent that can start batches without a ceiling is the nearest thing to
  # implicit that an explicit call can be.
  class StartBatch
    class Error < StandardError; end
    class NothingToAnalyze < Error; end
    class AgentCapExceeded < Error; end
    class CountMismatch < Error; end

    def self.call(filters:, concurrency:, started_via: OutcomeAnalysisBatch::STARTED_VIA_WEB_UI,
                  started_by_session: nil, expected_count: nil)
      new(filters: filters, concurrency: concurrency, started_via: started_via,
          started_by_session: started_by_session, expected_count: expected_count).call
    end

    # @param expected_count [Integer, nil] how many sessions the caller believes
    #   it is queuing. When given, a batch of any other size is refused and
    #   nothing is created. It is the MCP half of the web form's confirm dialog,
    #   which shows a human the count before the click lands: a filter typed
    #   wrong or left out widens a batch silently, and saying the number is how
    #   an agent looks before it leaps.
    def initialize(filters:, concurrency:, started_via: OutcomeAnalysisBatch::STARTED_VIA_WEB_UI,
                   started_by_session: nil, expected_count: nil)
      @filters = filters
      # Honor the number as typed — including the ill-advised ones. The floor is
      # the only clamp, because a batch with concurrency 0 would never start.
      # `Array(...).first` so an `?concurrency[]=2` query string narrows or is
      # ignored rather than raising, which is the same forgiveness LedgerFilters
      # applies to every other input on this form.
      @concurrency = [ Array(concurrency).first.to_i, OutcomeAnalysisBatch::MIN_CONCURRENCY ].max
      @started_via = started_via
      @started_by_session = started_by_session
      @expected_count = expected_count
    end

    def call
      enforce_agent_cap! if via_mcp?

      session_ids = LedgerQuery.new(@filters).analyzable_session_ids
      raise NothingToAnalyze, "No unanalyzed archived sessions match these filters." if session_ids.empty?
      if @expected_count && @expected_count != session_ids.size
        raise CountMismatch, "These filters match #{session_ids.size} unanalyzed archived " \
                             "#{'session'.pluralize(session_ids.size)}, not the #{@expected_count} expected. Nothing was queued."
      end

      batch = create_batch!(session_ids)

      # Start the first wave now rather than waiting up to a minute for the cron
      # tick, so the click has a visible effect.
      OutcomeAnalysisBatchPumpJob.perform_later(batch.id)
      batch
    end

    private

    def via_mcp? = @started_via == OutcomeAnalysisBatch::STARTED_VIA_MCP

    # Rejected rather than clamped: an agent that asked for 10 and silently got 3
    # would report the wrong thing to whoever asked it, and the message says
    # where the higher number is available.
    def enforce_agent_cap!
      if @concurrency > OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY
        raise AgentCapExceeded,
              "A batch started over MCP runs at most #{OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY} analyses at a time " \
              "(asked for #{@concurrency}). Pass a concurrency of #{OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY} or less; " \
              "a human can start a wider batch from the Analyze All button on /outcomes."
      end

      running = OutcomeAnalysisBatch.active.started_via_mcp.recent.first
      raise AgentCapExceeded, already_running_message(running) if running

      # Stop leaves a batch's in-flight analyses to finish, so without this a
      # stop-and-restart would stack a fresh wave on top of the stopped one's and
      # the ceiling would be per call again.
      in_flight = SpawnAnalysisSession.live_mcp_batch_item_count
      return unless in_flight.positive?

      raise AgentCapExceeded,
            "#{in_flight} #{'analysis'.pluralize(in_flight)} from a stopped MCP batch #{in_flight == 1 ? 'is' : 'are'} " \
            "still in flight. A new MCP batch waits for #{in_flight == 1 ? 'it' : 'them'} to finish, so stopping and " \
            "restarting cannot widen the ceiling."
    end

    # The batch row and its queue go in together, so no pump tick can find the
    # row with an empty queue and complete it. The partial unique index is what
    # actually holds "one running MCP batch": the check above is the friendly
    # message, this is the race it cannot see. `requires_new` so a losing INSERT
    # rolls back to a savepoint rather than poisoning a transaction the caller
    # is already in.
    def create_batch!(session_ids)
      OutcomeAnalysisBatch.transaction(requires_new: true) do
        batch = OutcomeAnalysisBatch.create!(
          filters: @filters.to_h,
          concurrency: @concurrency,
          status: OutcomeAnalysisBatch::RUNNING,
          total_count: session_ids.size,
          started_via: @started_via,
          started_by_session: @started_by_session
        )

        # One INSERT for the whole queue: an Analyze All over a few thousand
        # sessions must not be a few thousand round trips.
        now = Time.current
        rows = session_ids.each_with_index.map do |session_id, index|
          {
            outcome_analysis_batch_id: batch.id,
            session_id: session_id,
            state: OutcomeAnalysisBatchItem::QUEUED,
            position: index,
            created_at: now,
            updated_at: now
          }
        end
        OutcomeAnalysisBatchItem.insert_all!(rows)
        batch
      end
    rescue ActiveRecord::RecordNotUnique
      raise AgentCapExceeded, already_running_message(OutcomeAnalysisBatch.active.started_via_mcp.recent.first)
    end

    def already_running_message(batch)
      subject = batch ? "Batch ##{batch.id}" : "Another batch"
      "#{subject}, started over MCP, is still running, and only one MCP-started batch runs at a time. " \
        "Wait for it to finish, or stop it with the cancel_batch action#{batch ? " (batch_id: #{batch.id})" : ''}."
    end
  end
end
