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

  # How many session ids go into one `IN (...)` when reading labels. A year of
  # history is tens of thousands of sessions; slicing keeps each statement small.
  FLAG_BATCH = 5_000

  # @param session_scope [ActiveRecord::Relation] SessionTokenUsage already
  #   narrowed to the window every other figure on the page uses.
  # @param per_session [CostRollup, nil] that window's usage grouped by
  #   (session_id, agent_root). CostAnalytics passes the one it already holds for
  #   the top-sessions table, so the cohorts cost no scan of their own.
  def initialize(session_scope, per_session: nil)
    @per_session = per_session ||
      CostRollup.new(session_scope.where.not(session_id: nil), "session_id", "agent_root")
  end

  # One report per experimental setting.
  #
  # Every setting is answered from the same per-session rollup and one read of
  # the labels, joined in Ruby. Joining the usage table to the labels in SQL
  # would cost two priced scans of the window per setting.
  def reports
    settings = ExperimentalSettingsRegistry.all
    keys = settings.map(&:key)
    cohorts = cohorts_by_session(keys)
    tagging = tagging_counts(keys)

    settings.map { |setting| report_for(setting, cohorts[setting.key], tagging[setting.key]) }
  end

  private

  attr_reader :per_session

  def report_for(setting, cohort_of, tagging)
    cohorts = cohort_totals(cohort_of)

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
      paired_roots: paired_roots(cohort_of)
    }
  end

  # setting key => session id => cohort, for the sessions in the window. A
  # session with no label for a setting is absent, which is what keeps untagged
  # sessions out of every cohort, exactly as an INNER JOIN would.
  def cohorts_by_session(keys)
    result = keys.index_with { {} }
    session_ids = per_session.rows.map { |row| row.keys.first }.uniq

    session_ids.each_slice(FLAG_BATCH) do |ids|
      SessionExperimentalFlag
        .where(setting_key: keys, session_id: ids)
        .pluck(:setting_key, :session_id, Arel.sql(cohort_expression))
        .each { |key, session_id, cohort| result[key][session_id] = cohort }
    end

    result
  end

  # Usage in the window, bucketed by the cohort the session's flags put it in.
  # Untagged sessions and ad hoc spend simply are not in this report — that is
  # what the tagged/total counts on screen are for.
  def cohort_totals(cohort_of)
    rows = accumulate(cohort_of) { |cohort, _root| cohort }
    ALL_COHORTS.index_with { |cohort| rows[cohort] || metrics(0, 0, 0, 0) }
  end

  # How many sessions carry a label for each setting, and where each label came
  # from. Not restricted to the window: this answers "is the tagging working",
  # which is a property of the corpus, not of what you are looking at.
  def tagging_counts(keys)
    counts = keys.index_with { {} }
    SessionExperimentalFlag.where(setting_key: keys).group(:setting_key, :source).count
      .each { |(key, source), n| counts[key][source] = n }
    counts
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
  def paired_roots(cohort_of)
    by_root = Hash.new { |h, k| h[k] = {} }
    accumulate(cohort_of) { |cohort, root| [ cohort, root.to_s ] unless root.nil? || !COMPARED.include?(cohort) }
      .each { |(cohort, root), side| by_root[root][cohort] = side }

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

  # The per-session rollup summed into whatever buckets the block names, given
  # each row's cohort and agent root, with each bucket's DISTINCT session count —
  # which is why the rollup is per session rather than already per cohort.
  def accumulate(cohort_of)
    sums = Hash.new { |h, k| h[k] = { cost: 0.0, tokens: 0, calls: 0, sessions: Set.new } }

    per_session.rows.each do |row|
      session_id, root = row.keys
      cohort = cohort_of[session_id] or next
      bucket = yield(cohort, root) or next

      sum = sums[bucket]
      sum[:cost] += row.cost_usd
      sum[:tokens] += TokenAccounting::VOLUME_COLUMNS.sum { |c| row.sums[c] }
      sum[:calls] += row.sums[:api_calls]
      sum[:sessions] << session_id
    end

    sums.transform_values { |s| metrics(s[:cost], s[:tokens], s[:calls], s[:sessions].size) }
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
