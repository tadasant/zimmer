# frozen_string_literal: true

# Which of the four mechanisms is why a `waiting` session is waiting RIGHT NOW,
# and which are merely still on its row.
#
# == Why this exists
#
# A session can carry more than one park record at once — a spot start-hold, a
# mid-run ceiling pause and an auth-outage quota park all write their own keys
# into `metadata` and none of them clears the others. The surfaces that answer
# "why is this waiting" used to render whichever they happened to check first,
# which is how session 6808 read back a start-hold whose own re-check time was
# two days in the past while an auth-outage park a full day newer sat beside it
# unrendered, and session 7503 read back a ceiling pause fifteen seconds OLDER
# than the park next to it (tadasant/zimmer#642).
#
# That is not a cosmetic mistake, because the three mechanisms have three
# different resume owners: a ceiling pause is resumed by SpotCeilingSweepJob when
# utilization falls, a hold by its own re-check (repaired by SpotHoldSweepJob),
# and an outage park by whichever mechanism AuthOutageWakeAuthority gives it when
# the pool recovers — Zimmer's own sweep, or the ranked fleet wake. Naming the
# wrong mechanism points the reader at an owner that is not coming.
#
# == The fourth mechanism: queued for a worker
#
# The three above are dormancies — a session parked until something changes.
# Since #1040 `waiting` also holds the session whose turn has been HANDED OVER
# and is sitting in the `agents` GoodJob lane waiting for one of its
# `RunningTurns.worker_slots` threads. That is not a dormancy at all: nothing is
# wrong, nobody has to act, and the resume owner is GoodJob's own poller rather
# than a Zimmer sweep. It still has to be named here, because a surface that
# answers "why is this waiting" with silence — or with a stale spot hold — is
# lying about a session that is about to run.
#
# It is read off the JOB ROW, never off a metadata marker, and that is the whole
# reason it cannot go stale: a marker would survive a worker dying mid-turn and
# claim forever that a turn was coming. `JobLiveness` classifies the row, and
# only two of its verdicts count:
#
#   * `:queued` — ready, unclaimed, a worker takes it on its next poll.
#   * `:running` — a worker has it and has not stamped `running` yet, which is
#     the window in which the clone is made and the process spawned.
#
# `:scheduled` is deliberately excluded: a job parked on a future `scheduled_at`
# is a spot-gate re-check or a clone backoff, whose owner is the thing that
# parked it — naming GoodJob there would point the reader at the wrong sweep,
# which is the exact failure #642 was about. `:abandoned`, `:dead_worker` and
# `:interrupted` are corpses; a session behind one of those is stranded, and
# StrandedSleepRescue is its owner.
#
# == The rule
#
# **Newest wins.** Each mechanism stamps the moment it was recorded, and the last
# one to fire is the one that put the session where it is now. A mechanism with
# no timestamp ranks below every mechanism that has one, rather than winning by
# accident.
#
# **Except that an overdue hold cannot be the current reason while any other
# mechanism is present.** This is not a second opinion about recency, it is
# SpotSessionHold's own arithmetic read back: `SpotSessionHold.held_sessions`
# excludes a session that also carries a pause or a park, and `#rearm!` refuses
# one, so the sweep that repairs a stalled ladder will never touch it. A hold in
# that position is waiting on nothing, and `Record#recheck_sentence` — which
# promises "Zimmer's spot-hold sweep re-arms it automatically" — would be a false
# statement about it. An overdue hold that is the ONLY mechanism keeps the
# headline, because there the promise is true and the sweep is its real owner.
#
# Superseded mechanisms are returned rather than dropped: they are real records,
# and a reader who can see them ranked is better off than one who cannot see them
# at all.
class SessionWaitingReason
  SPOT_HOLD = :spot_hold
  SPOT_PAUSE = :spot_pause
  AUTH_OUTAGE_PARK = :auth_outage_park
  TURN_QUEUED = :turn_queued

  # The three mechanisms that mean "parked until something changes". TURN_QUEUED
  # is deliberately not one of them: a caller asking which dormancy a session is
  # under (Sessions::StopRecord) must not be handed a turn that is simply on its
  # way to a worker.
  DORMANCIES = [ SPOT_HOLD, SPOT_PAUSE, AUTH_OUTAGE_PARK ].freeze

  # The two mechanisms the spot ladder owns, which the session page's spot banner
  # picks between.
  SPOT_MECHANISMS = [ SPOT_HOLD, SPOT_PAUSE ].freeze

  # One mechanism found on the session. `label` is the noun phrase a surface uses
  # when it names this mechanism as something OTHER than the current reason, so
  # the ranked-second line reads as prose rather than as a metadata key.
  #
  # `demoted` is true only for the overdue-hold case above, and is carried on the
  # record because the sentence a surface prints about it is different: an older
  # mechanism is merely older, whereas a demoted hold has nothing coming for it.
  Mechanism = Data.define(:key, :at, :label, :demoted) do
    def demoted? = demoted
    def spot? = SPOT_MECHANISMS.include?(key)
    def dormancy? = DORMANCIES.include?(key)
  end

  # The ranking, split into the one mechanism that answers the question and the
  # ones that do not.
  Reading = Data.define(:current, :superseded) do
    def all = [ current, *superseded ]

    # The highest-ranked of the two SPOT mechanisms, which is what the session
    # page's spot banner renders — it draws one box for "in the spot queue" and
    # has to pick between a hold and a pause when the row carries both.
    def spot = all.find(&:spot?)

    # The highest-ranked mechanism that means "parked until something changes",
    # skipping a queued turn. For the caller that is classifying a DORMANCY and
    # would otherwise read a turn on its way to a worker as one.
    def dormancy = all.find(&:dormancy?)

    def current?(mechanism) = mechanism == current
  end

  class << self
    # @param session [Session, nil]
    # @return [Reading, nil] nil when none of the four mechanisms applies.
    def for(session)
      ranked = ranked(session)
      return nil if ranked.empty?

      Reading.new(current: ranked.first, superseded: ranked.drop(1))
    end

    # @return [Array<Mechanism>] most-current first.
    def ranked(session)
      return [] if session.nil?

      candidates = [ hold(session), pause(session), park(session), queued_turn(session) ].compact
      return candidates if candidates.size <= 1

      # Only ever the hold, and only when another DORMANCY could carry the headline
      # instead — which is exactly the condition under which the sweep drops it.
      # `#rearm!` skips a session that is `dormant_for_another_reason?`, and a
      # queued turn is not one of that predicate's arms, so a hold beside one is
      # still the sweep's to repair and must keep its promise (#1040).
      demote = hold_overdue?(session) && candidates.any? { |m| m.dormancy? && m.key != SPOT_HOLD }
      candidates = candidates.map { |m| m.key == SPOT_HOLD && demote ? m.with(demoted: true) : m }

      # All-numeric sort keys: a nil timestamp cannot be compared against a Time,
      # and the index keeps the order stable for two mechanisms stamped the same
      # second.
      candidates.each_with_index.sort_by { |m, i| [ m.demoted? ? 1 : 0, m.at ? 0 : 1, -(m.at&.to_f || 0.0), i ] }
                .map(&:first)
    end

    private

    def hold(session)
      record = SpotSessionHold.record_for(session) if SpotSessionHold.held?(session)
      return nil if record.nil?

      Mechanism.new(key: SPOT_HOLD, at: record.held_at, demoted: false,
                    label: "a spot-gate hold#{record.reason.present? ? " (`#{record.reason}`)" : ''}")
    end

    def pause(session)
      return nil unless SpotSessionPause.paused?(session)
      return nil if session.metadata&.dig(SpotSessionPause::PAUSED_DETAIL).blank?

      label = if SpotSessionPause.queued_by_user?(session)
        "a deliberate spot-queue park"
      elsif SpotSessionPause.preempted?(session)
        # Named apart from the ceiling pause it shares a record with: the two have
        # the same resume owner and completely different causes, and a reader sent
        # to "a quota window" for a slot a priority session took looks at the
        # wrong number.
        "a preemption by a priority session"
      else
        "a spot ceiling pause"
      end
      Mechanism.new(key: SPOT_PAUSE, at: parse_time(session.metadata&.dig(SpotSessionPause::PAUSED_AT)),
                    label: label, demoted: false)
    end

    # The turn this session has been handed, sitting in the `agents` lane.
    #
    # Rescued to nil rather than fabricated: this is the one mechanism that
    # reaches outside the `sessions` row, and every caller is a surface rendering
    # an explanation. A `good_jobs` read that fails should drop back to whatever
    # the row itself says, not invent a turn or blank the other three.
    def queued_turn(session)
      return nil unless session.waiting?

      jobs = Sessions::LiveTurn.unfinished_turns(session)
      return nil if jobs.empty?

      classified = jobs.map { |job| [ job, JobLiveness.status(job) ] }
      # Ready-and-unclaimed beats "a worker already has it" only in age; the
      # worker's own turn is the more advanced state, so it is preferred as the
      # answer when a session somehow has both.
      job, status = classified.find { |_job, st| st == :running } ||
                    classified.find { |_job, st| st == :queued }
      return nil if job.nil?

      label = if status == :running
        "a worker executing its turn's setup (its clone and process are being made)"
      else
        # No backticks: this label is rendered as prose by the session page's HTML
        # banner as well as by `get_session`'s markdown, and a literal backtick in
        # the browser reads as a typo. The markdown surface names the queue in
        # code style in its own sentence.
        "a place in the agents queue, behind the #{RunningTurns.worker_slots} worker threads " \
        "that run turns"
      end

      Mechanism.new(key: TURN_QUEUED, at: job.created_at, label: label, demoted: false)
    rescue StandardError => e
      Rails.logger.warn("[SessionWaitingReason] Could not read the agents queue for session " \
                        "#{session&.id} (#{e.class}: #{e.message}) — not naming a queued turn")
      nil
    end

    def park(session)
      return nil unless AuthOutageParkService.parked?(session)

      reason = session.metadata&.dig("auth_outage_reason")
      Mechanism.new(key: AUTH_OUTAGE_PARK, at: parse_time(session.metadata&.dig("auth_outage_parked_at")),
                    label: "an auth-outage park (`#{reason}`)", demoted: false)
    end

    # The same grace every other surface takes, so "stalled" is drawn in one place
    # (see SpotSessionHold::Record#overdue?).
    #
    # This is only ever asked when a second mechanism is present, which is what
    # makes it equivalent to the refusal it stands in for: `#rearm!` skips a
    # session that is `dormant_for_another_reason?`, and a pause or a park is two
    # of that predicate's three arms. Its third — a session asleep on a wall-clock
    # wake — is not a mechanism this ranks, so a hold beside one is a single
    # candidate and keeps the headline.
    def hold_overdue?(session)
      SpotSessionHold.record_for(session)&.overdue? || false
    end

    def parse_time(raw)
      return nil if raw.blank?

      Time.zone.parse(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
