# frozen_string_literal: true

# How the goal check read on the sessions that came to rest in a window: the
# measurement tadasant/zimmer#88 asked for before anything is allowed to act on a
# verdict.
#
# "At rest" is `needs_input` or `archived` — the two states a session ends a turn in
# when it believes it is done or needs a human. A session `running` or `waiting` has
# not claimed anything yet, so its verdict is provisional and not counted.
#
# The numbers are for reading the check's accuracy, so they break down the way a
# false reading shows up:
#
# - `unmet_reasons` / `pending_reasons` group sessions by WHICH criteria kept them
#   from `met`. A systematic misread is one criterion set with a large count, and the
#   sample ids are where to look.
# - `by_agent_root` shows a root whose sessions all read the same way — the shape
#   of the router misread GoalCheck's delegated-PR reading fixes, and of a root whose
#   default goal asks for a PR its work rarely produces.
# - `unmet_on_own_pull_request` is the population a re-prompt would act on: at rest,
#   holding a PR it recorded itself, and unmet only on criteria that PR's GitHub
#   state decides. Listed session by session, because each one is worth reading
#   before anything is built on the count.
#
# Windowed on the session's created_at, the same axis every other Outcomes surface
# uses. A missing `from` is DEFAULT_WINDOW before `to` (or before today), so the
# window is always bounded: this runs inside a web request and an MCP call.
class GoalCheckTally
  RESTING_STATUSES = %w[needs_input archived].freeze
  VERDICTS = %w[met unmet pending].freeze
  DEFAULT_WINDOW = 7.days
  SAMPLE_SIZE = 10
  OWN_PULL_REQUEST_LIMIT = 50
  BATCH_SIZE = 500

  # The only custom_metadata the check reads. Selecting these instead of the column
  # keeps a week of comment caches and transcript bookkeeping in the database.
  METADATA_SQL = "#{GoalCheck::DELEGATED_METADATA_SQL} AS custom_metadata"

  Row = Data.define(:key, :sessions, :met, :unmet, :pending)
  Reason = Data.define(:criteria, :sessions, :sample_session_ids)
  OwnPullRequest = Data.define(:session_id, :title, :status, :unmet_criteria)

  include SessionSearchable

  attr_reader :filters

  # @param filters [OutcomeAnalyses::LedgerFilters] from, to, agent_root and
  #   agent_runtime apply; model narrows on the session's configured model;
  #   analyzed and outcome are about analyses and are ignored
  def initialize(filters:)
    @filters = filters
  end

  def from_time
    filters.from_time || ((filters.to_time || Time.current) - DEFAULT_WINDOW).beginning_of_day
  end

  def to_time
    filters.to_time
  end

  # Every session at rest in the window, checked or not.
  def resting_sessions = compute[:resting]

  # Those whose goal is a catalog goal with checks.
  def checked_sessions = compute[:checked]

  def verdicts = compute[:verdicts]
  def criteria = compute[:criteria]
  def by_goal = rows_for(compute[:by_goal])
  def by_agent_root = rows_for(compute[:by_agent_root])
  def delegated_sessions = compute[:delegated]
  def unmet_reasons = reasons_for(compute[:unmet_reasons])
  def pending_reasons = reasons_for(compute[:pending_reasons])
  def unmet_on_own_pull_request_count = compute[:own_pull_request_count]
  def unmet_on_own_pull_request = compute[:own_pull_request]

  def any? = checked_sessions.positive?

  def to_h
    {
      window: { from: from_time&.iso8601, to: to_time&.iso8601 },
      resting_sessions: resting_sessions,
      checked_sessions: checked_sessions,
      verdicts: verdicts,
      delegated_sessions: delegated_sessions,
      criteria: criteria,
      unmet_reasons: unmet_reasons.map(&:to_h),
      pending_reasons: pending_reasons.map(&:to_h),
      by_goal: by_goal.map(&:to_h),
      by_agent_root: by_agent_root.map(&:to_h),
      unmet_on_own_pull_request: {
        sessions: unmet_on_own_pull_request_count,
        listed: unmet_on_own_pull_request.map(&:to_h)
      }
    }
  end

  private

  def scope
    sessions = Session.excluding_status_summary_forks.where(status: RESTING_STATUSES)
    sessions = sessions.where(created_at: from_time..) if from_time
    sessions = sessions.where(created_at: ..to_time) if to_time
    sessions = sessions.where(agent_runtime: filters.agent_runtime) if filters.agent_runtime
    sessions = sessions.where("config->>'model' = ?", filters.model) if filters.model
    sessions = filter_sessions_by_agent_root(sessions, filters.agent_root) if filters.agent_root
    sessions
  end

  def compute
    @compute ||= begin
      totals = {
        resting: scope.count,
        checked: 0,
        verdicts: VERDICTS.index_with(0),
        criteria: {},
        by_goal: {},
        by_agent_root: {},
        delegated: 0,
        unmet_reasons: {},
        pending_reasons: {},
        own_pull_request_count: 0,
        own_pull_request: []
      }

      scope.select(:id, :title, :status, :goal, :parent_session_id, :created_at,
                   Arel.sql("metadata->>'agent_root_key' AS agent_root_key"), Arel.sql(METADATA_SQL))
        .find_in_batches(batch_size: BATCH_SIZE) { |batch| tally_batch(batch, totals) }

      totals
    end
  end

  def tally_batch(batch, totals)
    delegated_ids = batch.select { |session| GoalCheck.reads_delegated_pull_requests?(session) }.map(&:id)
    delegates = delegated_ids.any? ? GoalCheck.delegated_pull_requests(delegated_ids) : {}

    batch.each do |session|
      check = GoalCheck.for(session, delegates: delegates.fetch(session.id, []))
      next unless check

      tally_session(session, check, totals)
    end
  end

  def tally_session(session, check, totals)
    totals[:checked] += 1
    totals[:verdicts][check.verdict] += 1
    totals[:delegated] += 1 if check.delegated?
    bump_row(totals[:by_goal], check.goal_id, check.verdict)
    bump_row(totals[:by_agent_root], session.attributes["agent_root_key"].presence || "(none)", check.verdict)

    check.criteria.each do |criterion|
      counts = totals[:criteria][criterion.key] ||= GoalCheck::STATUSES.index_with(0)
      counts[criterion.status] += 1
    end

    case check.verdict
    when "unmet"
      unmet = check.criteria.select { |c| c.status == "unmet" }.map(&:key)
      bump_reason(totals[:unmet_reasons], unmet, session.id)
      record_own_pull_request(session, check, unmet, totals)
    when "pending"
      bump_reason(totals[:pending_reasons], check.criteria.reject { |c| c.status == "met" }.map(&:key), session.id)
    end
  end

  def record_own_pull_request(session, check, unmet, totals)
    return if check.delegated?
    return unless (unmet - GoalCheck::PER_PULL_REQUEST_CRITERIA).empty?

    totals[:own_pull_request_count] += 1
    return if totals[:own_pull_request].size >= OWN_PULL_REQUEST_LIMIT

    totals[:own_pull_request] << OwnPullRequest.new(
      session_id: session.id, title: session.title, status: session.status, unmet_criteria: unmet
    )
  end

  def bump_row(rows, key, verdict)
    row = rows[key] ||= { sessions: 0 }.merge(VERDICTS.index_with(0).symbolize_keys)
    row[:sessions] += 1
    row[verdict.to_sym] += 1
  end

  def bump_reason(reasons, keys, session_id)
    reason = reasons[keys] ||= { sessions: 0, sample_session_ids: [] }
    reason[:sessions] += 1
    reason[:sample_session_ids] << session_id if reason[:sample_session_ids].size < SAMPLE_SIZE
  end

  def rows_for(rows)
    rows.map { |key, counts| Row.new(key: key, **counts) }.sort_by { |row| [ -row.sessions, row.key ] }
  end

  def reasons_for(reasons)
    reasons.map { |keys, counts| Reason.new(criteria: keys, **counts) }.sort_by { |reason| -reason.sessions }
  end
end
