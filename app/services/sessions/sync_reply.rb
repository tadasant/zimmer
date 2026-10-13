# frozen_string_literal: true

module Sessions
  # Hold a tool call open until the session has answered the prompt that call
  # sent it, and hand back the answer — the `sync: true` mode of `quick_router`,
  # `start_session` and `action_session` → `follow_up`.
  #
  # WHAT "THE ANSWER TO THAT PROMPT" MEANS. A session's conversation has many
  # turns, and the caller wants exactly one: the turn its prompt started. Two
  # things pin it down.
  #
  # * **When it ended** — `needs_input_count`, which every `pause` bumps inside
  #   the same transaction that writes the new status (and the `sleep` that may
  #   follow it). It is snapshotted at the moment the prompt is known to have
  #   been DELIVERED: before the send for a prompt that starts the next turn
  #   directly, and on first sight of its EnqueuedMessage leaving the queue for
  #   one that was queued behind a running turn. Any later bump is this turn
  #   ending, so a pause that ended the turn BEFORE ours — the common shape of a
  #   queued follow-up — is never mistaken for our answer. Two endings bump
  #   nothing and are caught directly: `archived` / `failed` (a session that
  #   archives itself straight from `running` never pauses), and a turn handed
  #   straight to a queued message, which shows as a later turn beginning in
  #   the transcript.
  # * **What it said** — the transcript from an index read before the send: our
  #   user message (for a queued prompt, the first one carrying our words) up to
  #   the next user message that is not a recovery continuation. The reply is
  #   the last assistant text in that window, so neither an earlier turn's reply
  #   nor a later one is returned.
  #
  # Not every pause is an answer. A recovery pause (`paused_by: "recovery"`) is
  # Zimmer restarting a process it lost mid-turn: it moves the baseline and the
  # wait goes on. A turn parked before it ran (an empty account pool, a setup
  # that could not deliver) is reported as stood down, and an MCP approval
  # request as blocked, not as answered.
  #
  # NO RECURSION. A Quick Router answers by starting a child session. The child
  # is listed — id, title, status, URL — and not waited on: its work can take
  # an hour, and the router's own reply already says what it started.
  #
  # CONCURRENCY. This holds a Puma thread for as long as it waits, and
  # production's web runs one Puma process with RAILS_MAX_THREADS (3). Three
  # things keep that from starving the web:
  #
  # 1. **No database connection while waiting.** The request's leased
  #    connection is returned to the pool before the first wait, and every
  #    re-read checks one out for that query alone.
  # 2. **A cap on concurrent waits** — MAX_CONCURRENT_WAITS per process, 1 by
  #    default. A call over the cap is not refused: its prompt is delivered as
  #    usual and it returns at once, saying so, exactly as `sync: false` would.
  # 3. **A ceiling on each wait** — MAX_TIMEOUT_SECONDS (see there for why 90).
  #
  # EVENT-DRIVEN, WITH A BACKSTOP. The wait is a Queue#pop on
  # Sessions::TurnSignal, rung after commit by every status change saved
  # through the model. Every ring means "re-read the row". The pop also times
  # out every BACKSTOP_SECONDS, because a status written with `update_columns`
  # does not ring, and a ring sent while solid_cable was still registering the
  # subscription can be lost; the backstop bounds what either costs.
  class SyncReply
    # The longest a sync call may hold. The binding limit in front of
    # production's /mcp is Cloudflare's edge, which cuts a request that has not
    # answered in 100s (and which a Free/Pro zone cannot raise); kamal-proxy's
    # `response_timeout` and Thruster's HTTP_WRITE_TIMEOUT are raised to 100 in
    # config/deploy.yml so that they are not the tighter one. 90 leaves the
    # create, the render and the hops their margin.
    MAX_TIMEOUT_SECONDS = Integer(ENV.fetch("MCP_SYNC_MAX_TIMEOUT_SECONDS", "90"))

    # What a caller gets without asking. Lower than the ceiling because the
    # client has a clock too: the MCP TypeScript SDK gives up on a request after
    # 60s by default, and a client that gives up never sees the session id —
    # the one thing it needs to fall back to polling. A caller that knows its
    # client waits longer asks for more.
    DEFAULT_TIMEOUT_SECONDS = [ Integer(ENV.fetch("MCP_SYNC_DEFAULT_TIMEOUT_SECONDS", "55")), MAX_TIMEOUT_SECONDS ].min
    MIN_TIMEOUT_SECONDS = 1

    MAX_CONCURRENT_WAITS = Integer(ENV.fetch("MCP_SYNC_MAX_CONCURRENT_WAITS", "1"))

    BACKSTOP_SECONDS = 5

    # The reply is returned whole up to this, and cut from the front past it:
    # the end of a long answer is the part that answers.
    REPLY_MAX_CHARS = 20_000

    CHILDREN_LIMIT = 10

    # How a wait ended. Everything but :timed_out and :over_capacity means the
    # turn is over.
    OUTCOMES = %i[
      needs_input asleep moved_on blocked_on_elicitation stood_down archived failed undelivered timed_out
      over_capacity
    ].freeze

    # User messages Zimmer writes to resume a turn it lost (a restarted process,
    # an OOM kill, a rebuilt clone). They continue our turn rather than start the
    # next one, so the reply window runs on through them. Matched on each
    # template's fixed opening, up to its first placeholder.
    CONTINUATION_PREFIXES = [
      AutomatedPrompts::SYSTEM_RECOVERY,
      AutomatedPrompts::MEMORY_LIMIT_RECOVERY_TEMPLATE,
      AutomatedPrompts::SHARED_MEMORY_LIMIT_RECOVERY_TEMPLATE,
      AutomatedPrompts::LOST_CLONE_RECOVERY_TEMPLATE
    ].map { |template| template.split("%{").first.squish.first(160) }.freeze

    # What the transcript says about our turn: whether our prompt has arrived,
    # whether a later turn has begun after it, and what was said in between.
    TurnWindow = Struct.new(:started, :over, :texts)

    Result = Struct.new(:session, :outcome, :reply, :reply_truncated, :children, :elapsed_seconds,
                        :queued_position, keyword_init: true) do
      def finished? = !%i[timed_out over_capacity].include?(outcome)
    end

    @semaphore = Concurrent::Semaphore.new(MAX_CONCURRENT_WAITS)
    class << self
      attr_reader :semaphore

      # The timeout a caller asked for, clamped to what the transport tolerates.
      # Raises ArgumentError on something that is not a number.
      def timeout_from(value)
        return DEFAULT_TIMEOUT_SECONDS if value.nil? || value.to_s.strip.empty?

        seconds = Float(value)
        raise ArgumentError, "sync_timeout_seconds must be a positive number" unless seconds.positive?

        seconds.clamp(MIN_TIMEOUT_SECONDS, MAX_TIMEOUT_SECONDS)
      end

      # Take a wait slot for the block, or return nil without running it when
      # every slot is in use.
      def with_slot
        return nil unless semaphore.try_acquire

        begin
          yield
        ensure
          semaphore.release
        end
      end

      def reset_semaphore!(permits = MAX_CONCURRENT_WAITS)
        @semaphore = Concurrent::Semaphore.new(permits)
      end
    end

    # A new session's first turn: nothing has paused and nothing is in the
    # transcript before it. The same coordinates serve an idempotent replay of
    # the create, however far that session has got since — and so do the
    # sessions it started, counted from its creation rather than the replay.
    def self.first_turn(session, prompt:)
      new(session: session, prompt: prompt, needs_input_count: 0, transcript_index: 0,
          children_since: session.created_at)
    end

    # The coordinates for a prompt that starts an existing session's next turn
    # directly: a follow-up to an idle one. Take them BEFORE sending.
    def self.direct(session, prompt:)
      new(session: session, prompt: prompt,
          needs_input_count: session.needs_input_transition_count,
          transcript_index: session.transcript_line_count)
    end

    # The coordinates for a prompt that went into the session's queue. The
    # pause baseline is read when the message is seen to leave the queue. The
    # transcript is read from where it stood at the enqueue, and our turn starts
    # at the first user message carrying our words — however late the waiter
    # notices the delivery, the window cannot begin after our prompt.
    # `transcript_index` is read by the caller BEFORE it queues the message.
    def self.queued(session, prompt:, enqueued_message:, transcript_index:)
      new(session: session, prompt: prompt, enqueued_message_id: enqueued_message.id,
          transcript_index: transcript_index, match_prompt: true)
    end

    def initialize(session:, prompt:, needs_input_count: nil, transcript_index: nil, enqueued_message_id: nil,
                   match_prompt: false, children_since: nil, clock: Process)
      @session_id = session.id
      @session = session
      @prompt = prompt.to_s
      @needs_input_count = needs_input_count
      @transcript_index = transcript_index
      @enqueued_message_id = enqueued_message_id
      @match_prompt = match_prompt
      @clock = clock
      @children_since = children_since || (Time.current - 1.second)
    end

    attr_reader :session_id

    # Wait up to `timeout` seconds. Always returns a Result; never raises for a
    # session that misbehaves, because the prompt has already been delivered and
    # the caller must get its session id back whatever happens next.
    def wait(timeout:)
      started = now
      deadline = started + timeout
      rings = Thread::Queue.new
      unsubscribe = subscribe { rings << true }
      release_request_connection!

      loop do
        outcome = with_fresh_connection { evaluate }
        return with_fresh_connection { result(outcome, started) } if outcome

        remaining = deadline - now
        return with_fresh_connection { result(:timed_out, started) } if remaining <= 0

        rings.pop(timeout: [ remaining, BACKSTOP_SECONDS ].min)
        rings.clear
      end
    ensure
      unsubscribe&.call
    end

    # The answer a call over the concurrency cap gets: the state right now.
    def over_capacity
      result(:over_capacity, now)
    end

    private

    def evaluate
      @session = Session.find(@session_id)
      return :archived if @session.archived?
      return :failed if @session.failed?

      unless delivered?
        return :undelivered if @undelivered

        return nil
      end

      count = @session.needs_input_transition_count
      if count > @needs_input_count
        # Zimmer restarting a process it lost: the same turn, carried on.
        if @session.needs_input? && @session.recovery_pause?
          @needs_input_count = count
          return nil
        end

        return answered(paused_outcome)
      end

      # Paused mid-turn on an approval, without the turn ending.
      return :blocked_on_elicitation if @session.needs_input? && @session.blocked_on_elicitation?
      # A turn handed straight to a queued message ends without a pause, so the
      # count cannot say so; the transcript can, by a later turn beginning.
      return answered(:moved_on) if turn_window.over

      nil
    end

    # How a turn that paused came to rest.
    def paused_outcome
      # A turn Zimmer parked before the agent ever ran it (an empty account pool,
      # an undeliverable setup) pauses like any other, with nothing said.
      return :stood_down if @session.turn_stood_down_before_it_ran?
      # `block_on_elicitation` counts as a pause too.
      return :blocked_on_elicitation if @session.needs_input? && @session.blocked_on_elicitation?
      return :needs_input if @session.needs_input?
      return :moved_on if @session.running?
      return :asleep if @session.armed_one_time_wake? || !Sessions::LiveTurn.coming?(@session)

      :moved_on
    end

    # A queued prompt that the turn it should have started never carried —
    # cancelled from the queue, say — is not an answer.
    def answered(outcome)
      return :undelivered if @match_prompt && !turn_window.started

      outcome
    end

    # For a queued prompt: has it left the queue? The pause baseline is read at
    # the first sight of that. Every move the handoff makes is a status change,
    # so the sight comes on a ring, long before the turn it starts can end.
    def delivered?
      return true if @needs_input_count

      message = EnqueuedMessage.find_by(id: @enqueued_message_id)
      if message && message.status == "undelivered"
        @undelivered = true
        return false
      end
      return false if message && %w[pending processing].include?(message.status)

      @needs_input_count = @session.needs_input_transition_count
      true
    end

    def result(outcome, started)
      @session = Session.find(@session_id)
      reply, truncated = finish_reply(turn_window.texts)
      Result.new(
        session: @session,
        outcome: outcome,
        reply: reply,
        reply_truncated: truncated,
        children: children,
        elapsed_seconds: (now - started).round(1),
        queued_position: queued_position
      )
    end

    # Scanned again only when the transcript has grown since the last look.
    def turn_window
      lines = @session.transcript_line_count
      return @turn_window if @turn_window && @scanned_lines == lines

      @scanned_lines = lines
      @turn_window = scan_transcript(lines)
    end

    # From the baseline index: our turn opens at the first user message (or,
    # for a queued prompt, the first carrying our words) and runs until a user
    # message that is neither ours nor a recovery continuation. The reply is
    # the last assistant text in between — or, mid-turn, the latest so far.
    def scan_transcript(lines)
      window = TurnWindow.new(false, false, [])
      return window if @transcript_index.nil? || lines <= @transcript_index

      normalizer = TranscriptRuntime.normalizer_for(@session)
      source = TranscriptRuntime.source_for(@session)
      catch(:turn_over) do
        @session.each_transcript_line(@transcript_index, lines) do |index, line|
          source.parse_events(line).each do |raw|
            normalizer.normalize(raw, session: @session, transcript_index: index).each do |event|
              next if OpenTranscript.blank_message?(event)

              case event[:type]
              when OpenTranscript::Types::USER_MESSAGE
                text = TranscriptTextRenderer.content_text(event[:content]).squish
                if !window.started
                  window.started = true if !@match_prompt || own_prompt?(text)
                elsif !own_prompt?(text) && !continuation?(text)
                  window.over = true
                  throw :turn_over
                end
              when OpenTranscript::Types::ASSISTANT_MESSAGE
                window.texts << TranscriptTextRenderer.content_text(event[:content]).strip if window.started
              end
            end
          end
        end
      end
      window
    end

    def finish_reply(texts)
      text = texts.reject(&:blank?).last
      return [ nil, false ] if text.nil?
      return [ text, false ] if text.length <= REPLY_MAX_CHARS

      [ "…#{text[-REPLY_MAX_CHARS..]}", true ]
    end

    # Our words, possibly inside a wrapper Zimmer adds. A resumed delivery can
    # repeat them, and that is still our turn.
    def own_prompt?(text)
      head = @prompt.squish.first(80)
      head.present? && text.include?(head)
    end

    def continuation?(text)
      CONTINUATION_PREFIXES.any? { |prefix| text.start_with?(prefix) }
    end

    def children
      Session.where(parent_session_id: @session_id)
        .where(created_at: @children_since..)
        .order(:id)
        .limit(CHILDREN_LIMIT)
        .to_a
    end

    def queued_position
      return nil unless @enqueued_message_id && @needs_input_count.nil?

      EnqueuedMessage.find_by(id: @enqueued_message_id)&.position
    end

    def subscribe(&)
      TurnSignal.subscribe(@session_id, &)
    rescue StandardError => e
      Rails.logger.warn("[Sessions::SyncReply] Could not subscribe to session #{@session_id}: #{e.class}: " \
                        "#{e.message} — waiting on the #{BACKSTOP_SECONDS}s backstop alone")
      nil
    end

    # Hand the request's connection back so a waiting thread holds none. Not
    # inside a transaction: releasing there would drop it.
    def release_request_connection!
      pool = ActiveRecord::Base.connection_pool
      connection = pool.active_connection
      return if connection.nil? || connection.transaction_open?

      pool.release_connection
    end

    def with_fresh_connection(&)
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do
        ActiveRecord::Base.uncached(&)
      end
    end

    def now
      @clock.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
