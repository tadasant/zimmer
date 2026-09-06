# frozen_string_literal: true

# Which mechanism is allowed to wake an auth-outage-parked session — asked once,
# answered in one place.
#
# == Why this is a class and not a conditional ==
#
# Two mechanisms resume the sessions AuthOutageParkService parks, and they cover
# different populations:
#
#   * The SWEEP — AuthOutageParkService.wake_parked_sessions!, run by
#     QuotaResetCheckerJob every fifteen minutes.
#   * The FLEET wake — the one fleet-maintenance session Zimmer spawns on the
#     `quota_available` trigger event, which runs the `awaken-waiting-sessions`
#     policy and ranks what it starts by `precedence`.
#
# Until tadasant/zimmer#617 the boundary between them existed only as prose,
# written down four times — in AuthOutageParkService's header, in
# QuotaResetCheckerJob's, in `get_session`'s resume sentence, in the session
# page's banner — and re-derived from `session.spot?` at each. The fleet-side
# policy lives in a different repository and believed it owned the WHOLE parked
# population, so both sides claimed the priority parks. Five times between
# 2026-08-22 and 2026-08-25 the fleet wake enumerated them, watched the sweep
# resume them mid-run, tripped its own collision check, stopped waking
# altogether, and handed the recovery — including the spot population only it can
# rank — to a sweep that reads neither `precedence` nor the concurrency ceiling.
#
# A rule stated in four comments is a rule nothing enforces. This is the one
# statement of it: the sweep branches on it, and every surface that tells a human
# or an agent who is coming for a parked session renders its sentence.
#
# == The boundary ==
#
#   PRIORITY parks -> SWEEP.
#     Priority work is never gated on quota and there is no ordering question to
#     get wrong, so it recovers with the accounts. Making it wait for a session
#     to be spawned and take its first turn would be a regression, and it would
#     put every priority park behind a trigger that can be disabled.
#
#   SPOT parks -> FLEET.
#     Spot work is exactly the work whose order matters when quota is scarce. The
#     sweep has no notion of order — oldest park first, stop at a cap — so waking
#     spot work there is the arbitrary start `precedence` exists to replace.
#
# Neither owner may wake a session that is ALSO asleep on a wake-up somebody
# chose; that guard sits ahead of this question entirely, in the sweep.
#
# == Derived, never stored ==
#
# The owner is computed from the session's scheduling class every time it is
# asked, rather than stamped into the park record at park time. A session's class
# can be changed while it is parked, and a stored owner would then name a
# mechanism that is no longer looking for it — a park owned by nobody, which is
# the stranding shape of tadasant/zimmer#655. Derived, a reclassified session
# simply changes hands on the next sweep.
class AuthOutageWakeAuthority
  # AuthOutageParkService.wake_parked_sessions!, every fifteen minutes.
  SWEEP = :sweep

  # The fleet-maintenance session spawned by the `quota_available` event.
  FLEET = :fleet

  OWNERS = [ SWEEP, FLEET ].freeze

  class << self
    # @param session [Session, nil]
    # @return [Symbol] SWEEP or FLEET. A nil session answers FLEET rather than
    #   raising: the sweep's own guard is #sweep_owned?, and the safe default for
    #   a session it cannot classify is "not mine".
    def for(session)
      return FLEET if session.nil?

      session.spot? ? FLEET : SWEEP
    end

    # Is Zimmer's own sweep the mechanism that resumes this parked session?
    def sweep_owned?(session) = self.for(session) == SWEEP

    # Is the ranked fleet wake the mechanism that starts this parked session?
    def fleet_owned?(session) = self.for(session) == FLEET

    # How a parked session's own resume happens, as one sentence, with no leading
    # capital — the surfaces that render it supply their own stem ("Resumes
    # when:", "It resumes when"). One source so the human reading the session
    # page and the agent reading `get_session` are told the same thing.
    def resume_sentence(session)
      if fleet_owned?(session)
        "the account pool recovers and the ranked fleet wake reaches it in precedence order " \
        "(currently #{session.precedence}). Nothing is cancelled and no action is needed."
      else
        "the account pool recovers — Zimmer's own auth-outage sweep resumes it, within fifteen " \
        "minutes. Nothing is cancelled and no action is needed."
      end
    end

    # The same fact stated as an instruction, for the agent surfaces.
    #
    # `get_session` and `quick_search_sessions` are what the fleet wake reads to
    # decide what to restart, so the boundary has to be legible THERE — a policy
    # that has to infer it from the scheduling class is the arrangement that
    # produced #617. This says which mechanism owns the park and, for the half
    # the fleet wake must not touch, that it must not touch it.
    def instruction(session)
      if fleet_owned?(session)
        "the ranked fleet wake (the `quota_available` event). This park is the fleet wake's to " \
        "start, in precedence order, within the spot thresholds and the concurrency ceiling."
      else
        "Zimmer's own auth-outage sweep (`AuthOutageParkService.wake_parked_sessions!`), which " \
        "runs every fifteen minutes. Zimmer resumes this one itself — the fleet wake must not " \
        "restart it, and a wake it did not issue is this sweep, not a collision."
      end
    end
  end
end
