# frozen_string_literal: true

module Sessions
  # A human speaking to a spot session moves it to the head of the spot queue and
  # gets it going, and sends the least human-involved session in that queue to
  # the bottom in exchange.
  #
  # == What "a human intervenes" means, and why it can be said precisely
  #
  # A HumanMessage row on THIS session. Nothing else.
  #
  # Zimmer already draws that line, and draws it at the input boundary rather
  # than from the text: HumanMessageCapture writes a record only when the
  # authenticated actor was established — Tadas typing into the web UI, or a
  # Slack user id that resolves through the seeded roster. An agent's `follow_up`
  # over MCP, a router-composed spawn prompt, a fired `wake_me_up_later`, a
  # heartbeat nudge, a polled GitHub comment and a system-recovery resume all
  # arrive as the same kind of `user` turn and record NOTHING. So "a human
  # intervened" is a question the data answers exactly, with no heuristic in it,
  # and treating a router's follow-up as a human — which is what keying on "a
  # prompt arrived" would do — is the one mistake that would make this feature
  # promote most of the fleet.
  #
  # HERE, not the hierarchy. SessionHumanMessages gathers a whole tree and marks
  # every record `here` or `elsewhere` precisely because the second is context
  # about intent and not an instruction to this session. A human talking to a
  # router is not intervening in the twelve sessions under it.
  #
  # == Creating a session is not intervening in one
  #
  # The boundaries that CREATE a session (the new-session form, the Quick
  # Router's prompt box) capture a HumanMessage too, and they already decide
  # placement for themselves — the Quick Router's "Run as spot" checkbox is where
  # `top_of_spot` came from. Promoting on those would re-place a session that was
  # just placed and, worse, demote somebody on every new human-typed session,
  # which is not an exchange anybody asked for. So they are named and skipped.
  #
  # == Placing it is not enough on its own
  #
  # A promotion that lands the rank and nothing else is tadasant/zimmer#423: the
  # class change was applied, the session sat exactly as long as before, and the
  # queue's own re-check was still up to an hour out. So the promotion goes
  # through Sessions::StartNow, the same door the Ranked view's Start entry and a
  # promote-to-priority use — which pulls a deferred turn forward rather than
  # enqueuing a second one.
  #
  # Moving a turn is not passing the gate, and this does not pretend otherwise:
  # the session stays spot, so a full fleet or a spent budget holds it again. What
  # it buys is the front of the queue and the next slot, which is what "get going
  # immediately" can honestly mean for spot work.
  #
  # == The demotion, and why it is bounded
  #
  # The promotion is zero-sum by design: without a counterweight every
  # intervention adds SLOT_GAP to the top of the queue forever, and the numbers
  # inflate away from anything an operator set by hand. So one session goes to the
  # bottom.
  #
  # "Least human involved" is the same reading as the trigger — HumanMessage rows
  # on the session itself — and the candidate is chosen by:
  #
  #   1. Fewest human messages. A session with none anywhere is the natural
  #      answer and the common one.
  #   2. Oldest last human message (a session with none sorts first). Between two
  #      sessions a person has spoken to twice each, the one they have not
  #      touched for a week is the less involved.
  #   3. Fewest prior demotions of this kind, so the same session is not the
  #      answer every time.
  #   4. Lowest precedence, then newest. The queue's own order, and then the
  #      session with least waiting behind it.
  #
  # Three refusals bound it, and each of them can end in demoting NOBODY, which
  # is a perfectly good outcome:
  #
  #   * **Nobody less involved than the promoted session.** The promoted session
  #     has just been spoken to, so its count is at least one; a candidate must be
  #     STRICTLY below it. When every queued session is as involved as this one,
  #     the queue has no less-wanted work in it and there is nothing to trade.
  #   * **Age exemption.** A session that has been in the queue longer than
  #     STARVATION_EXEMPTION is never demoted, whatever its involvement. This is
  #     the anti-starvation rule, and it is stated as a rule rather than left to
  #     luck: an unattended session sinks at most until it is a day old, and from
  #     then on every promotion goes past it rather than over it. Without it,
  #     "least human involvement" is a property that never changes on a session
  #     nobody talks to, so the same row would be demoted forever.
  #   * **The spot queue only.** Candidates are spot sessions dormant in
  #     `waiting`. A running session is not in the queue — re-ranking it changes
  #     nothing about what it is doing and only charges it later — and a priority
  #     session is not ordered by precedence at all.
  #
  # The demoted session is not stopped, not cancelled and not held: it keeps its
  # turn, its record and its resume owner, and the only thing that changed is an
  # integer. It runs when the queue above it drains — and one message from a
  # human puts it straight back on top.
  class HumanInterventionPromotion
    # The capture boundaries that mean "a human created this session" rather than
    # "a human intervened in one". Matched on HumanMessage#entry_point, which is
    # the specific boundary the capture recorded rather than the coarse channel.
    CREATION_ENTRY_POINTS = %w[web_ui.new_session web_ui.quick_prompt].freeze

    # How long a session has to have been waiting before it stops being
    # demotable. The anti-starvation floor — see the class comment.
    STARVATION_EXEMPTION = 24.hours

    # How far below the bottom of the queue a demoted session lands, and the
    # durable count of how often that has happened to it.
    DEMOTED_COUNT = "spot_demoted_count"
    DEMOTED_AT = "spot_demoted_at"

    # What happened, for the log line and for the tests. `promoted` is nil when
    # the intervention was not one this acts on at all.
    Result = Data.define(:promoted, :precedence, :started, :demoted) do
      def acted? = !promoted.nil?
    end

    NOTHING = Result.new(promoted: nil, precedence: nil, started: nil, demoted: nil).freeze

    class << self
      # @param human_message [HumanMessage]
      # @return [Result]
      def call(human_message, logger: nil)
        logger ||= StructuredLogger.new({ service: "Sessions::HumanInterventionPromotion" })
        session = human_message&.session
        return NOTHING unless intervention?(human_message, session)

        promoted_to = promote!(session, logger)
        return NOTHING if promoted_to.nil?

        started = start_now(session, logger)
        demoted = demote_least_involved!(session, logger)

        logger.info("A human intervened in a spot session",
          session_id: session.id, precedence: promoted_to,
          started: started, demoted_session_id: demoted&.id)

        Result.new(promoted: session, precedence: promoted_to, started: started, demoted: demoted)
      # Never raises. Its caller is a background job hanging off a HumanMessage
      # write, and the message itself has already been delivered — a re-ranking
      # that fails must not look like a failure of the thing a person actually
      # asked for.
      rescue StandardError => e
        logger&.warn("Could not act on a human intervention",
          human_message_id: human_message&.id, error: "#{e.class}: #{e.message}")
        NOTHING
      end

      # Whether this record is a human intervening in an existing spot session.
      def intervention?(human_message, session)
        return false if human_message.nil? || session.nil?
        return false if CREATION_ENTRY_POINTS.include?(human_message.entry_point)
        return false if session.archived?
        return false unless session.spot?
        return false if session.status_summary_fork?

        true
      end

      # Every spot session dormant in the queue — the population a demotion picks
      # from, and the population the head of the queue is measured against.
      def queued_spot_sessions
        Session.spot.where(status: :waiting)
      end

      private

      # @return [Integer, nil] the precedence it landed on, or nil if unchanged
      def promote!(session, logger)
        # Measured against the queue MINUS itself and floored at its current
        # value, which is what the instance form of the placement is for: "put
        # this first" applied to the row already on top must not walk it up
        # SLOT_GAP on every message, and must never LOWER a rank.
        target = session.precedence_for_place(SessionPrecedence::PLACE_TOP_OF_SPOT)
        return session.precedence if target == session.precedence

        session.update!(precedence: target)
        session.logs.create!(level: "info", content: promotion_message(session, target))
        target
      rescue StandardError => e
        logger.warn("Could not promote a spot session a human intervened in",
          session_id: session.id, error: "#{e.class}: #{e.message}")
        nil
      end

      # Landing the rank and stopping there is #423. A `waiting` session gets its
      # queued turn pulled forward; anything else already has a turn in hand.
      #
      # @return [Boolean, nil] nil when there was nothing to start
      def start_now(session, logger)
        return nil unless session.reload.waiting?

        result = Sessions::StartNow.call(session, actor: "a human message")
        logger.info("Start-now on an intervened session",
          session_id: session.id, outcome: result.outcome, message: result.message)
        result.started?
      rescue StandardError => e
        logger.warn("Could not start a spot session a human intervened in",
          session_id: session.id, error: "#{e.class}: #{e.message}")
        nil
      end

      # @return [Session, nil] the session sent to the bottom, or nil for "nobody
      #   in this queue is less involved than the one that was just promoted"
      def demote_least_involved!(promoted, logger)
        candidates = queued_spot_sessions.where.not(id: promoted.id)
          .where(created_at: STARVATION_EXEMPTION.ago..).to_a
        return nil if candidates.empty?

        involvement = involvement_for([ promoted, *candidates ])
        bar = involvement.fetch(promoted.id, [ 0, nil ]).first
        # STRICTLY less involved. A queue in which everything has been spoken to
        # as much as this session has is a queue with nothing less wanted in it.
        candidates = candidates.select { |s| involvement.fetch(s.id, [ 0, nil ]).first < bar }
        return nil if candidates.empty?

        victim = candidates.min_by do |s|
          count, last_at = involvement.fetch(s.id, [ 0, nil ])
          [ count, last_at&.to_i || 0, demoted_count(s), s.precedence.to_i, -s.created_at.to_i, -s.id ]
        end

        demote!(victim, promoted, logger)
      end

      # @return [Session, nil]
      def demote!(victim, promoted, logger)
        bottom = queued_spot_sessions.where.not(id: victim.id).minimum(:precedence)
        target = Session.clamp_precedence(
          (bottom.nil? ? SessionPrecedence::DEFAULT : bottom) - SessionPrecedence::SLOT_GAP
        )
        # A session already at or below the bottom is left where it is. Its rank
        # is already the answer, and rewriting it would walk the whole scale down
        # by SLOT_GAP on every intervention for no change in the ORDER.
        return nil if target >= victim.precedence

        victim.update!(precedence: target)
        victim.merge_metadata!(
          DEMOTED_COUNT => demoted_count(victim) + 1,
          DEMOTED_AT => Time.current.utc.iso8601
        )
        victim.logs.create!(level: "info", content: demotion_message(promoted, target))
        logger.info("Demoted the least human-involved spot session",
          session_id: victim.id, precedence: target, for_session_id: promoted.id)
        victim
      rescue StandardError => e
        logger.warn("Could not demote a spot session",
          session_id: victim.id, error: "#{e.class}: #{e.message}")
        nil
      end

      def demoted_count(session)
        (session.metadata || {})[DEMOTED_COUNT].to_i
      end

      # session id => [count of human messages, when the last one was].
      #
      # One grouped query for the whole population rather than one per session.
      # Counted on the session ITSELF — see the class comment on `here`.
      def involvement_for(sessions)
        HumanMessage.where(session_id: sessions.map(&:id))
          .group(:session_id)
          .pluck(Arel.sql("session_id, COUNT(*), MAX(occurred_at)"))
          .to_h { |id, count, last_at| [ id, [ count.to_i, last_at ] ] }
      end

      def promotion_message(session, target)
        "A human sent this session a message, so it moved to the head of the spot queue " \
          "(precedence #{target}) and its next turn was brought forward. It is still a spot session: " \
          "the gate decides whether it runs, and a full fleet or a spent budget holds it again — but " \
          "it is now ahead of everything else queued. Class: #{session.priority_class}."
      end

      def demotion_message(promoted, target)
        "Moved to the bottom of the spot queue (precedence #{target}). A human intervened in session " \
          "##{promoted.id}, which went to the head of the queue; this session was the least " \
          "human-involved one queued, so it made room. Nothing was cancelled and no turn was lost — " \
          "it runs when the queue above it drains, and one message from a human puts it back on top. " \
          "A session that has been queued for over #{STARVATION_EXEMPTION.inspect} is never demoted " \
          "again, so this cannot repeat indefinitely."
      end
    end
  end
end
