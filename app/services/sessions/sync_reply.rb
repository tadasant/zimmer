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
  #   queued follow-up — is never mistaken for our answer. `archived` and
  #   `failed` end it whatever the count says; a session that archives itself
  #   straight from `running` never pauses at all.
  # * **What it said** — the transcript from the event index snapshotted at the
  #   same moment: the first user message from there (ours) up to the next one.
  #   The reply is the last assistant text in that window, so an earlier turn's
  #   reply is never returned, and neither is a later one when a queued message
  #   took the next turn before we looked.
  #
  # A recovery pause (`paused_by: "recovery"`) is Zimmer restarting a process
  # it lost mid-turn, not the turn ending, so it moves the baseline and the wait
  # goes on.
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
    DEFAULT_TIMEOUT_SECONDS = MAX_TIMEOUT_SECONDS
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
      needs_input asleep moved_on blocked_on_elicitation archived failed undelivered timed_out over_capacity
    ].freeze

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
    # the create, however far that session has got since.
    def self.first_turn(session, prompt:)
      new(session: session, prompt: prompt, needs_input_count: 0, transcript_index: 0)
    end

    # The coordinates for a prompt that starts an existing session's next turn
    # directly: a follow-up to an idle one. Take them BEFORE sending.
    def self.direct(session, prompt:)
      new(session: session, prompt: prompt,
          needs_input_count: session.needs_input_transition_count,
          transcript_index: session.transcript_line_count)
    end

    # The coordinates for a prompt that went into the session's queue: they are
    # read when the message is seen to leave it.
    def self.queued(session, prompt:, enqueued_message:)
      new(session: session, prompt: prompt, enqueued_message_id: enqueued_message.id)
    end

    def initialize(session:, prompt:, needs_input_count: nil, transcript_index: nil, enqueued_message_id: nil,
                   clock: Process)
      @session_id = session.id
      @session = session
      @prompt = prompt.to_s
      @needs_input_count = needs_input_count
      @transcript_index = transcript_index
      @enqueued_message_id = enqueued_message_id
      @clock = clock
      @sent_at = Time.current
    end

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
        if @session.needs_input? && @session.recovery_pause?
          @needs_input_count = count
          return nil
        end

        return :needs_input if @session.needs_input?
        return :asleep if @session.waiting? && @session.armed_one_time_wake?

        return :moved_on
      end

      return :blocked_on_elicitation if @session.needs_input? && @session.blocked_on_elicitation?

      nil
    end

    # For a queued prompt: has it left the queue? The baseline is read at the
    # first sight of that, before the turn it starts can have ended — the spawn
    # alone takes longer than a backstop interval.
    def delivered?
      return true if @needs_input_count

      message = EnqueuedMessage.find_by(id: @enqueued_message_id)
      if message && message.status == "undelivered"
        @undelivered = true
        return false
      end
      return false if message && %w[pending processing].include?(message.status)

      @needs_input_count = @session.needs_input_transition_count
      @transcript_index = @session.transcript_line_count
      true
    end

    def result(outcome, started)
      @session = Session.find(@session_id)
      reply, truncated = reply_text
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

    # The last assistant text of our turn — or, while it is still running, of
    # what it has said so far. Nil when nothing has been said, or when the
    # prompt never left the queue.
    def reply_text
      return [ nil, false ] if @transcript_index.nil?

      texts = []
      started = false
      normalizer = TranscriptRuntime.normalizer_for(@session)
      source = TranscriptRuntime.source_for(@session)
      catch(:turn_over) do
        @session.each_transcript_line(@transcript_index, @session.transcript_line_count) do |index, line|
          source.parse_events(line).each do |raw|
            normalizer.normalize(raw, session: @session, transcript_index: index).each do |event|
              next if OpenTranscript.blank_message?(event)

              case event[:type]
              when OpenTranscript::Types::USER_MESSAGE
                throw :turn_over if started && !own_prompt?(event)
                started = true
              when OpenTranscript::Types::ASSISTANT_MESSAGE
                texts << TranscriptTextRenderer.content_text(event[:content]).strip if started
              end
            end
          end
        end
      end
      finish_reply(texts)
    end

    def finish_reply(texts)
      text = texts.reject(&:blank?).last
      return [ nil, false ] if text.nil?
      return [ text, false ] if text.length <= REPLY_MAX_CHARS

      [ "…#{text[-REPLY_MAX_CHARS..]}", true ]
    end

    # A second user message that carries our own words is the same turn (a
    # resumed delivery can repeat the prompt); any other user message is the
    # next turn starting.
    def own_prompt?(event)
      head = @prompt.squish.first(80)
      head.present? && TranscriptTextRenderer.content_text(event[:content]).squish.include?(head)
    end

    def children
      Session.where(parent_session_id: @session_id)
        .where(created_at: (@sent_at - 1.second)..)
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
