# frozen_string_literal: true

# The cohort comparison behind the Costs page's "Experimental settings" report:
# for each experimental setting, what spend looked like on each side of it.
#
# WHAT THIS IS NOT
#
# It is not a controlled experiment, and the report says so on screen. Nothing
# here randomizes anything. A setting is global, so a cohort is "every session
# that ran while it was on" — and for a setting backfilled from the date it
# landed, that is exactly "every session before a date" versus "every session
# after". Anything else that changed at that date is perfectly confounded with
# the setting, and the biggest movers of session cost (which agent root ran, on
# which model, for how long, doing what) are not held constant either.
#
# So the rollup is built to make that visible rather than to hide it:
#
#   * every cohort carries its own `sessions` and `api_calls` count, because a
#     dramatic-looking delta over four sessions is noise and the reader has to be
#     able to see that it is four;
#   * the headline metric is cost PER API CALL, not per session. Per-session cost
#     mostly measures how long sessions happened to be, which is task mix, not
#     the setting. Per-session is still reported — it is what the bill feels like
#     — but it is labelled as the confounded one;
#   * `paired_roots` compares the same agent root against itself across the two
#     cohorts and reports only roots present on both sides, which removes the
#     single largest source of task mix;
#   * a session whose start and end values disagree is its own `mixed` cohort,
#     never averaged into either side;
#   * a comparison whose thinner side is below MIN_SESSIONS / MIN_CALLS reports
#     `comparable: false`, and the view refuses to print a percentage for it.
class ExperimentAnalytics
  # Below this, a delta is not worth printing as a number. Deliberately modest —
  # the point is to catch "three sessions on one side", not to impose a power
  # calculation on a deployment that runs tens of sessions a day.
  MIN_SESSIONS = 5
  MIN_CALLS = 50

  # Cohorts that are a real side of the comparison, in display order. "mixed" and
  # "unknown" are reported but never compared.
  COMPARED = %w[off on].freeze
  ALL_COHORTS = %w[off on mixed unknown].freeze

  # @param session_scope [ActiveRecord::Relation] SessionTokenUsage already
  #   narrowed to the window every other figure on the page uses.
  def initialize(session_scope)
    @session_scope = session_scope
  end

  # One report per experimental setting.
  def reports
    ExperimentalSettingsRegistry.all.map { |setting| report_for(setting) }
  end

  def report_for(setting)
    cohorts = cohort_totals(setting.key)
    tagging = tagging_counts(setting.key)

    {
      key: setting.key,
      title: setting.title,
      description: setting.description,
      current_value: setting.current_value,
      landed_at: setting.landed_at,
      backfilled: setting.backfillable?,
      tagged_sessions: tagging.values.sum,
      tagged_by_source: tagging,
      cohorts: cohorts,
      comparison: comparison(cohorts),
      paired_roots: paired_roots(setting.key)
    }
  end

  private

  attr_reader :session_scope

  # Usage in the window, grouped by the cohort the session's flags put it in.
  # An INNER JOIN, so untagged sessions and ad hoc spend simply are not in this
  # report — that is what the tagged/total counts on screen are for.
  def cohort_totals(key)
    rows = flagged(key)
      .group(Arel.sql(cohort_expression))
      .pluck(
        Arel.sql(cohort_expression),
        SessionTokenUsage.cost_sum_sql,
        SessionTokenUsage.total_tokens_sql,
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(DISTINCT session_token_usages.session_id)")
      )
      .to_h { |cohort, cost, tokens, calls, sessions| [ cohort.to_s, metrics(cost, tokens, calls, sessions) ] }

    ALL_COHORTS.index_with { |cohort| rows[cohort] || metrics(0, 0, 0, 0) }
  end

  # How many sessions carry a label for this setting, and where each label came
  # from. Not restricted to the window: this answers "is the tagging working",
  # which is a property of the corpus, not of what you are looking at.
  def tagging_counts(key)
    SessionExperimentalFlag.for_setting(key).group(:source).count
  end

  # Whether the two sides can be compared, and — when they cannot — WHICH of the
  # two reasons applies. They call for different sentences: "widen the window"
  # answers a thin cohort and is nonsense in front of a cohort of forty sessions
  # whose models simply have no price configured. A single `comparable: false`
  # made the page print the wrong one.
  def comparison(cohorts)
    off = cohorts["off"]
    on = cohorts["on"]
    cost_per_call_change = change(off[:cost_per_call], on[:cost_per_call])

    too_few = COMPARED.any? do |cohort|
      cohorts[cohort][:sessions] < MIN_SESSIONS || cohorts[cohort][:api_calls] < MIN_CALLS
    end

    reason =
      if too_few then :too_few
      elsif cost_per_call_change.nil? then :no_baseline
      end

    {
      comparable: reason.nil?,
      reason: reason,
      min_sessions: MIN_SESSIONS,
      min_calls: MIN_CALLS,
      cost_per_call_change: cost_per_call_change,
      cost_per_session_change: change(off[:cost_per_session], on[:cost_per_session]),
      tokens_per_call_change: change(off[:tokens_per_call], on[:tokens_per_call])
    }
  end

  # The same agent root on both sides of the setting, which is the closest thing
  # to a like-for-like comparison this data can offer: it holds constant the
  # single variable that moves session cost most. Roots present on only one side
  # are dropped rather than shown with half a row — a root that only ever ran
  # under one cohort tells you about scheduling, not about the setting.
  def paired_roots(key)
    grouped = flagged(key)
      .where.not(agent_root: nil)
      .group(Arel.sql(cohort_expression), :agent_root)
      .pluck(
        Arel.sql(cohort_expression),
        :agent_root,
        SessionTokenUsage.cost_sum_sql,
        SessionTokenUsage.total_tokens_sql,
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(DISTINCT session_token_usages.session_id)")
      )

    by_root = Hash.new { |h, k| h[k] = {} }
    grouped.each do |cohort, root, cost, tokens, calls, sessions|
      next unless COMPARED.include?(cohort.to_s)
      by_root[root.to_s][cohort.to_s] = metrics(cost, tokens, calls, sessions)
    end

    by_root
      .select { |_, sides| COMPARED.all? { |cohort| sides[cohort] } }
      .map do |root, sides|
        {
          agent_root: root,
          off: sides["off"],
          on: sides["on"],
          cost_per_call_change: change(sides["off"][:cost_per_call], sides["on"][:cost_per_call])
        }
      end
      .sort_by { |row| -(row[:off][:cost_usd] + row[:on][:cost_usd]) }
  end

  # Usage rows in the window joined to this setting's per-session label.
  def flagged(key)
    session_scope.joins(
      SessionTokenUsage.sanitize_sql_array([
        "INNER JOIN session_experimental_flags ON session_experimental_flags.session_id = " \
        "session_token_usages.session_id AND session_experimental_flags.setting_key = ?", key
      ])
    )
  end

  def cohort_expression = SessionExperimentalFlag.cohort_sql

  def metrics(cost, tokens, calls, sessions)
    cost = cost.to_f
    tokens = tokens.to_i
    calls = calls.to_i
    sessions = sessions.to_i

    {
      cost_usd: cost,
      tokens: tokens,
      api_calls: calls,
      sessions: sessions,
      cost_per_call: calls.positive? ? cost / calls : nil,
      cost_per_session: sessions.positive? ? cost / sessions : nil,
      tokens_per_call: calls.positive? ? tokens.to_f / calls : nil
    }
  end

  # Relative change from `before` to `after`, or nil when either side is missing
  # or the baseline is zero. Negative is cheaper.
  def change(before, after)
    return nil if before.nil? || after.nil? || before.zero?

    (after - before) / before
  end
end
