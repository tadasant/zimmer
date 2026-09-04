# frozen_string_literal: true

# Which of the three dormancy mechanisms is why a `waiting` session is waiting
# RIGHT NOW, and which are merely still on its row.
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
# and an outage park by AuthOutageParkService.wake_parked_sessions! when the pool
# recovers. Naming the wrong mechanism points the reader at an owner that is not
# coming.
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

  # One mechanism found on the session. `label` is the noun phrase a surface uses
  # when it names this mechanism as something OTHER than the current reason, so
  # the ranked-second line reads as prose rather than as a metadata key.
  #
  # `demoted` is true only for the overdue-hold case above, and is carried on the
  # record because the sentence a surface prints about it is different: an older
  # mechanism is merely older, whereas a demoted hold has nothing coming for it.
  Mechanism = Data.define(:key, :at, :label, :demoted) do
    def demoted? = demoted
    def spot? = key != AUTH_OUTAGE_PARK
  end

  # The ranking, split into the one mechanism that answers the question and the
  # ones that do not.
  Reading = Data.define(:current, :superseded) do
    def all = [ current, *superseded ]

    # The highest-ranked of the two SPOT mechanisms, which is what the session
    # page's spot banner renders — it draws one box for "in the spot queue" and
    # has to pick between a hold and a pause when the row carries both.
    def spot = all.find(&:spot?)

    def current?(mechanism) = mechanism == current
  end

  class << self
    # @param session [Session, nil]
    # @return [Reading, nil] nil when the session is dormant on none of the three.
    def for(session)
      ranked = ranked(session)
      return nil if ranked.empty?

      Reading.new(current: ranked.first, superseded: ranked.drop(1))
    end

    # @return [Array<Mechanism>] most-current first.
    def ranked(session)
      return [] if session.nil?

      candidates = [ hold(session), pause(session), park(session) ].compact
      return candidates if candidates.size <= 1

      # Only ever the hold, and only when something else could carry the headline
      # instead — which is exactly the condition under which the sweep drops it.
      candidates = candidates.map { |m| m.key == SPOT_HOLD && hold_overdue?(session) ? m.with(demoted: true) : m }

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

      label = SpotSessionPause.queued_by_user?(session) ? "a deliberate spot-queue park" : "a spot ceiling pause"
      Mechanism.new(key: SPOT_PAUSE, at: parse_time(session.metadata&.dig(SpotSessionPause::PAUSED_AT)),
                    label: label, demoted: false)
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
