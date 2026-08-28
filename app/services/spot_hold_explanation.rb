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
  # @param paused_count [Integer] SpotSessionPause.paused_count
  def initialize(decision, paused_count:)
    @decision = decision
    @paused_count = paused_count.to_i
  end

  # @return [Array<Line>] empty when spot work is running — there is no hold to
  #   explain.
  def lines
    return [] if @decision.allowed?

    [
      Line.new(label: "Why it's held", sentence: why),
      Line.new(label: "Held until", sentence: held_until)
    ]
  end

  # Rendered whether or not spot work is held. "0 asleep" is the answer to "did
  # the ceiling actually stop anything?", and a backlog left over from an earlier
  # ceiling is worth seeing even after the gate reopens.
  #
  # Deliberately does not restate the count. Both surfaces print the number
  # immediately before this sentence, so repeating it reads as a stutter.
  def sessions_asleep
    return "None is asleep in the spot queue." if @paused_count.zero?

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

  private

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

  def spot_budget_why
    "The #{windows_phrase} spot budget is spent — everything above the priority reserve. This is the " \
      "one ceiling that also pauses spot sessions already running, so the window stops climbing into " \
      "the reserve instead of eating it."
  end

  # The comparison the gate actually made: the fleet PLUS the session being
  # admitted, against the sustainable rate. Printing the fleet's burn alone would
  # show a number below the sustainable rate and leave the reader wondering why
  # anything is held.
  def pacing_curve_why
    "The #{windows_phrase} spot budget still has #{remaining_phrase} left, but the fleet at " \
      "#{rate(@decision.fleet_burn_usd_per_minute)} plus the #{rate(@decision.candidate_burn_usd_per_minute)} " \
      "the next spot session is priced at comes to #{rate(@decision.projected_burn_usd_per_minute)}, against " \
      "#{rate(@decision.sustainable_usd_per_minute)} sustainable. New spot turns wait at the door so what " \
      "is left is spread over the rest of the window. Spot sessions already running are not paused for " \
      "this; only a spent budget does that."
  end

  def spot_budget_until(seconds)
    return "The #{windows_phrase} rollover, which could not be read." if seconds.nil?

    "No sooner than the #{windows_phrase} rollover, about #{rollover_phrase(seconds)}. Only a " \
      "rollover puts money back in the budget."
  end

  def burn_must_fall_until(seconds)
    sentence = "#{burn_threshold_clause} Waiting alone does not get there: the sustainable rate is the " \
               "budget left divided by the time left, so while the fleet outruns it that rate keeps " \
               "falling. Running sessions finishing is what closes the gap."

    return sentence if seconds.nil?

    "#{sentence} Failing that, the #{windows_phrase} rollover refills the budget, about " \
      "#{rollover_phrase(seconds)} — an upper bound on the wait, not a forecast of it."
  end

  # How far the FLEET has to fall, which is the sustainable rate less what the
  # session being admitted is itself projected to spend. When that is zero or
  # negative, one session alone is priced above what the window can sustain, and
  # the only thing that runs is the duty cycle the idle-fleet waiver produces.
  def burn_threshold_clause
    sustainable = @decision.sustainable_usd_per_minute
    return "When the fleet's burn falls back inside what the window can sustain." if sustainable.nil?

    headroom = sustainable - @decision.candidate_burn_usd_per_minute.to_f
    if headroom.positive?
      "When the fleet's burn falls below #{rate(headroom)} — #{rate(sustainable)} sustainable, less the " \
        "#{rate(@decision.candidate_burn_usd_per_minute)} the next spot session is priced at."
    else
      "Not until the fleet empties. One session on its own is priced above the #{rate(sustainable)} this " \
        "window can sustain, so nothing fits beside the work already running; with nothing running at " \
        "all the pace test is waived and a single session goes again."
    end
  end

  # Always named as an estimate: this is a pool AVERAGE of when each account's
  # window turns over, not a clock Zimmer owns.
  def rollover_phrase(seconds)
    "#{distance_of_time_in_words(seconds)} from now (estimated from the pool average)"
  end

  # "weekly" or "5-hour and weekly", possessive, for a sentence about the windows
  # that actually refused. Falls back to a bare "window's" when the decision
  # carries no window at all, which is the fleet-cap case.
  def windows_phrase
    labels = @decision.held_windows.keys
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
  def resumption_clause
    verb = @decision.ceiling == :spot_budget ? "is pausing running spot sessions right now" :
      "is not pausing anything right now"
    subject = @paused_count == 1 ? "It resumes" : "They resume"

    "The ceiling #{verb}. #{subject} automatically once the fleet is back inside the budget with " \
      "#{SpotGateService::RESUME_MARGIN_PCT} points of the window to spare."
  end

  def rate(value)
    return "an unknown rate" if value.nil?

    "#{money(value)}/min"
  end

  def money(value)
    return "an unknown amount" if value.nil?
    return "unbounded" if value.respond_to?(:infinite?) && value.infinite?

    helpers.number_to_currency(value, precision: value.abs < 100 ? 2 : 0)
  end

  def helpers = ActionController::Base.helpers
end
