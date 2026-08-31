# frozen_string_literal: true

# The two sentences a human needs when spot work is held — which ceiling is
# holding it, and what lifts the hold — plus the one that says how many sessions
# are asleep because of it.
#
# == Why this exists
#
# SpotGateService produces one `detail` sentence, and it has to serve every
# caller: a log line, a session banner, the /quotas card. On /quotas that left
# the obvious follow-up questions unanswered, and the card answered one of them
# wrong.
#
# `at_utilization_limit` covers TWO different ceilings — a window whose
# non-reserved budget is spent, and a window that still has budget but is being
# spent faster than it can carry. Only the first pauses spot sessions that are
# already running (SpotGateService::Reading#stops_running_work?). The card
# branched on the reason string alone, so it announced "running spot sessions
# are being paused too" during every pacing hold, claiming work was being
# interrupted when none was.
#
# It also rendered SpotSessionPause.paused_count under the label "Running spot
# sessions paused for the ceiling", which reads as a count of RUNNING sessions.
# They are dormant in `waiting`, which is how that figure reaches 17 on a page
# whose next line says four sessions are running.
#
# == On "held until"
#
# Two of the three ceilings have no forecast in them, and this class says so
# rather than inventing one.
#
# The pacing curve is the case worth being blunt about. The sustainable rate is
# the remaining spot budget divided by the time left in the window, so while the
# fleet burns faster than that rate, the numerator falls faster than the
# denominator and the rate keeps DROPPING. Waiting widens the gap rather than
# closing it. The hold lifts when the fleet's burn falls — running sessions
# ending is what does that — or when the window rolls over and refills the
# budget. The rollover is therefore an upper bound on the wait, not a prediction
# of it, and it is labelled as one.
class SpotHoldExplanation
  include ActionView::Helpers::DateHelper

  # `label` is what the surface puts in front of the sentence. The /quotas card
  # and `get_spot_policy` render the same pairs, so the two cannot drift.
  Line = Data.define(:label, :sentence)

  # @param decision [SpotGateService::Decision]
  # @param paused_count [Integer] SpotSessionPause.paused_count — sessions the
  #   ceiling interrupted MID-RUN
  # @param held_count [Integer] SpotSessionHold.held_count — sessions the gate
  #   refused BEFORE a turn. A different population with a different resume
  #   owner, which is why it gets its own figure rather than being folded in.
  # @param overdue_hold_count [Integer] how many of those are past their own
  #   re-check time, i.e. how many ladders have stalled
  def initialize(decision, paused_count:, held_count: 0, overdue_hold_count: 0)
    @decision = decision
    @paused_count = paused_count.to_i
    @held_count = held_count.to_i
    @overdue_hold_count = overdue_hold_count.to_i
  end

  # @return [Array<Line>] empty when spot work is running — there is no hold to
  #   explain.
  # Memoized: the /quotas card asks whether there are any before rendering them,
  # and every sentence is rebuilt from the decision each time otherwise.
  def lines
    @lines ||= if @decision.allowed?
      []
    else
      [
        Line.new(label: "Why it's held", sentence: why),
        Line.new(label: "Held until", sentence: held_until)
      ]
    end
  end

  # Rendered whether or not spot work is held. "0 asleep" is the answer to "did
  # the ceiling actually stop anything?", and a backlog left over from an earlier
  # ceiling is worth seeing even after the gate reopens.
  #
  # Deliberately does not restate the count. Both surfaces print the number
  # immediately before this sentence, so repeating it reads as a stutter.
  def sessions_asleep
    return "The ceiling has stopped nothing, or has already put everything back." if @paused_count.zero?

    if @paused_count == 1
      "It was paused mid-run when a window's spot budget ran out, and is asleep rather than running, " \
        "so it counts toward neither the sessions-running figure nor the concurrency limit. " \
        "#{resumption_clause}"
    else
      "Each was paused mid-run when a window's spot budget ran out, and they are asleep rather than " \
        "running, so they count toward neither the sessions-running figure nor the concurrency limit. " \
        "#{resumption_clause}"
    end
  end

  # The other dormant population, and the one both surfaces used to omit
  # entirely.
  #
  # `get_spot_policy` printed SpotSessionPause.paused_count under the heading
  # "Spot sessions asleep in the spot queue", which reads as every dormant spot
  # session and is not. On 2026-08-31 it reported 0 asleep while session 7507 —
  # spot, `waiting`, held 145 times — was demonstrably asleep on a hold. The two
  # populations are disjoint and clear differently: a pause is resumed by
  # SpotCeilingSweepJob when the window falls, a hold by its own re-check.
  #
  # The overdue figure is the one an operator acts on. A hold past its own
  # re-check time is a ladder that has stopped, and until SpotHoldSweepJob existed
  # nothing surfaced that at all.
  def sessions_held
    return "Nothing is waiting at the door — no spot turn has been refused and not yet let through." if
      @held_count.zero?

    subject = @held_count == 1 ? "It is" : "Each is"
    pronoun = @held_count == 1 ? "It re-checks itself" : "They re-check themselves"
    # No backticks around "waiting": this sentence is rendered as plain text on
    # /quotas as well as into `get_spot_policy`'s markdown, and the page shows
    # them literally.
    sentence = "#{subject} dormant in waiting before a turn the gate refused — a different population " \
               "from the paused one above, and asleep rather than running, so it counts toward neither " \
               "the sessions-running figure nor the concurrency limit. #{pronoun} on a backoff ladder " \
               "and comes back with the turn it was holding."

    return sentence if @overdue_hold_count.zero?

    "#{sentence} #{overdue_clause}"
  end

  private

  # A stalled ladder, named. `spot_hold_retry_at` is the whole promise a held
  # session rests on, so one in the past means the session is waiting on nothing.
  def overdue_clause
    tail = "SpotHoldSweepJob puts %s back on within a few minutes."

    if @overdue_hold_count > 1
      "#{@overdue_hold_count} of them are past their own re-check time: those ladders have stalled, " \
        "and #{tail % 'them'}"
    elsif @held_count > 1
      "One of them is past its own re-check time: that ladder has stalled, and #{tail % 'it'}"
    else
      # "One of them", with exactly one held session, reads as though there were
      # others.
      "Its own re-check time has already passed: the ladder has stalled, and #{tail % 'it'}"
    end
  end

  def why
    case @decision.ceiling
    when :fleet_cap then fleet_cap_why
    when :spot_budget then spot_budget_why
    when :pacing_curve then pacing_curve_why
    else @decision.detail
    end
  end

  def held_until
    kind, seconds = @decision.resume_outlook

    case kind
    when :fleet_cap then "A slot frees up when a running session finishes. Nothing here predicts when."
    when :spot_budget then spot_budget_until(seconds)
    when :burn_must_fall then burn_must_fall_until(seconds)
    else @decision.detail
    end
  end

  def fleet_cap_why
    "Every session slot is taken — #{@decision.active_sessions} of #{@decision.fleet_cap}. No quota " \
      "window is holding anything. Priority sessions occupy slots too, and are meant to crowd spot " \
      "work out of them."
  end

  # Names only the windows whose budget is actually SPENT, not every window that
  # refused. With the 5-hour budget gone and the weekly window merely ahead of its
  # curve, `held_windows` holds both and "the 5-hour and weekly windows' spot
  # budget is spent" would be false of the second.
  def spot_budget_why
    "The #{windows_phrase(@decision.budget_spent_windows)} spot budget is spent — everything above the " \
      "priority reserve. This is the one ceiling that also pauses spot sessions already running, so the " \
      "window stops climbing into the reserve instead of eating it."
  end

  def pacing_curve_why
    "The #{windows_phrase(@decision.held_windows)} spot budget still has #{remaining_phrase} left, but " \
      "#{pace_comparison}. New spot turns wait at the door so what is left is spread over the rest of " \
      "the window. Spot sessions already running are not paused for this; only a spent budget does that."
  end

  # The comparison the gate actually made: the fleet PLUS the session being
  # admitted, against the sustainable rate. Printing the fleet's burn alone would
  # show a number below the sustainable rate and leave the reader wondering why
  # anything is held.
  #
  # A window with no calibrated dollars, or a deployment with no sampled burn
  # rates yet, is paced on cumulative percentages instead — there is no rate to
  # print, and inventing one would be worse than naming the curve.
  def pace_comparison
    fleet = @decision.fleet_burn_usd_per_minute
    candidate = @decision.candidate_burn_usd_per_minute
    sustainable = @decision.sustainable_usd_per_minute
    return "the window is already past where its pacing curve says it should be by now" if
      fleet.nil? || candidate.nil? || sustainable.nil?

    "the fleet at #{rate(fleet)} plus the #{rate(candidate)} the next spot session is priced at comes " \
      "to #{rate(@decision.projected_burn_usd_per_minute)}, against #{rate(sustainable)} sustainable"
  end

  def spot_budget_until(seconds)
    windows = windows_phrase(@decision.budget_spent_windows)
    return "The #{windows} rollover, which could not be read." if seconds.nil?

    "No sooner than the #{windows} rollover, #{rollover_phrase(seconds)}. Only a rollover puts money " \
      "back in the budget."
  end

  def burn_must_fall_until(seconds)
    sentence = "#{burn_threshold_clause} Waiting alone does not get there: the sustainable rate is the " \
               "budget left divided by the time left, so while the fleet outruns it that rate keeps " \
               "falling. Running sessions finishing is what closes the gap."

    return sentence if seconds.nil?

    "#{sentence} Failing that, the #{windows_phrase(@decision.held_windows)} rollover refills the " \
      "budget #{rollover_phrase(seconds)} — an upper bound on the wait, not a forecast of it."
  end

  # How far the FLEET has to fall: the sustainable rate less what the session
  # being admitted is itself projected to spend, because the gate tests the sum
  # of the two. "To or below" rather than "below" — Window#within_pace? is `<=`.
  #
  # When that headroom is zero or negative, one session on its own is priced
  # above what the window can sustain, so no amount of fleet burn admits it while
  # anything is running. What runs then is the duty cycle the idle-fleet waiver
  # produces, and the copy says that rather than printing a negative threshold.
  def burn_threshold_clause
    sustainable = @decision.sustainable_usd_per_minute
    candidate = @decision.candidate_burn_usd_per_minute
    return "When the fleet's spending falls back inside what the window can carry." if
      sustainable.nil? || candidate.nil?

    headroom = sustainable - candidate
    return above_sustainable_clause(sustainable) unless headroom.positive?

    "When the fleet's burn falls to or below #{rate(headroom)} — #{rate(sustainable)} sustainable, less " \
      "the #{rate(candidate)} the next spot session is priced at. The budget and a free slot have to " \
      "hold as well."
  end

  def above_sustainable_clause(sustainable)
    "Not while anything is running: one session on its own is priced above the #{rate(sustainable)} " \
      "this window can sustain, so nothing fits beside the work already in flight. With nothing running " \
      "at all the pace test is waived and a single session goes again."
  end

  # Always named as an estimate: this is a pool AVERAGE of when each account's
  # window turns over, not a clock Zimmer owns. No "about" of its own —
  # `distance_of_time_in_words` supplies one for most durations, and prepending a
  # second gives "about about 2 hours".
  def rollover_phrase(seconds)
    "in #{distance_of_time_in_words(seconds)} (estimated from the pool average)"
  end

  # "weekly window's" or "5-hour and weekly windows'", for a sentence about a
  # specific set of windows. Falls back to a bare "window's" when the set is
  # empty, which is the fleet-cap case.
  def windows_phrase(windows)
    labels = windows.keys
    return "window's" if labels.empty?

    "#{labels.to_sentence} #{'window'.pluralize(labels.size)}#{labels.size > 1 ? "'" : "'s"}"
  end

  def remaining_phrase
    remaining = @decision.held_windows.each_value.filter_map { |r| r.window.remaining_spot_usd }.min
    return "room" if remaining.nil?

    money(remaining)
  end

  # Whether the ceiling is pausing work RIGHT NOW, which is the question the old
  # copy answered wrong. Only a spent budget ever is.
  #
  # The resume condition is the WHOLE gate, not just the budget: SpotSessionPause
  # resumes on `SpotGateService.resume_decision.allowed?`, which tests the cap,
  # the pacing curve and a free slot. Saying "back inside the budget" would
  # promise a resume during a pacing hold that has room but no pace.
  def resumption_clause
    verb = @decision.ceiling == :spot_budget ? "is pausing running spot sessions right now" :
      "is not pausing anything right now"
    subject = @paused_count == 1 ? "It resumes" : "They resume"

    "The ceiling #{verb}. #{subject} automatically once the gate allows spot work again — budget, " \
      "pacing curve and a free slot — with #{SpotGateService::RESUME_MARGIN_PCT} points of the window " \
      "held back on top of the reserve while they come back."
  end

  # A $/min figure. Rates run three orders of magnitude smaller than budgets, so
  # two decimals would render a real $0.004/min threshold as "$0.00/min".
  def rate(value)
    return "an unknown rate" if value.nil?
    return "an unbounded rate" if value.respond_to?(:infinite?) && value.infinite?

    "#{helpers.number_to_currency(value, precision: value.abs < 0.01 ? 4 : 2)}/min"
  end

  def money(value)
    return "an unknown amount" if value.nil?
    return "unbounded" if value.respond_to?(:infinite?) && value.infinite?

    helpers.number_to_currency(value, precision: value.abs < 100 ? 2 : 0)
  end

  def helpers = ActionController::Base.helpers
end
