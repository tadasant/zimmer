# frozen_string_literal: true

# Labels the history a live recorder can never reach.
#
# SessionExperimentalFlag tags a session as it starts and as it ends, which works
# for every session from this deploy onward and for none of the thousands that
# ran before it. For a setting that shipped as a step change — MCP tool search
# landed enabled for everyone in b59d9ad7 — the label for those older sessions is
# recoverable from their timestamps, and this job writes it.
#
# The inference is honest about being one. Rows written here carry
# `source = "backfilled"`, the Costs report counts them separately from observed
# ones, and a session that straddles the boundary (created before, still running
# after) is labelled `mixed` by the same start/end disagreement a mid-session
# toggle produces — so it is bucketed out of both cohorts rather than assigned to
# one by rounding.
#
# Ops action, not a rake task: there is no shell on the production box, so the
# only way this runs is a cron tick after the deploy. Idempotent by construction
# — it inserts only rows that do not exist, so the second tick and every tick
# after it is one indexed anti-join that writes nothing.
#
# QUEUE PLACEMENT — `default`, like TokenUsageBackfillJob and for the same
# reason: bulk work does not belong on the `pollers` threads.
class ExperimentalFlagBackfillJob < ApplicationJob
  queue_as :default

  # How far back the cutoff falls when nothing has been observed yet — the first
  # tick after this ships, when every session in the table is history and there is
  # no observation to anchor to. The hour of margin keeps a session created
  # seconds ago, not yet started and so not yet tagged, from being labelled
  # "backfilled" by a tick that lands between its creation and its first turn.
  LIVE_RECORDER_GRACE = 1.hour

  # One backfill at a time. Two would race on the same unique index for no gain.
  good_job_control_concurrency_with(
    key: -> { "experimental_flag_backfill" },
    total_limit: 1
  )

  def perform
    cutoff = tracking_started_at
    ExperimentalSettingsRegistry.backfillable.sum { |setting| backfill(setting, cutoff) }
  end

  private

  # The moment live tracking demonstrably began: the earliest observation any
  # session carries. Nothing at or after it may be inferred from a date.
  #
  # This bound is the difference between labelling history and inventing the
  # present. `landed_at` describes ONE step change, so a date-derived label is
  # only ever right for sessions that predate tracking — the instant the operator
  # toggles a setting by hand, every later toggle is invisible to it. Without the
  # cutoff, a session parked in `waiting` for an hour would be labelled from its
  # creation date, run under whatever the setting had since become, and land in
  # `mixed` — which is to say the backfill would silently destroy exactly the
  # interleaved cohort a deliberate toggle was flipped to collect.
  #
  # Falls back to a grace period before the first observation exists, which is
  # the one tick where "everything older than an hour" really is all history.
  def tracking_started_at
    SessionExperimentalFlag.observed.minimum(:first_observed_at) || LIVE_RECORDER_GRACE.ago
  end

  # One INSERT ... SELECT per setting. Cohort labels come from two timestamps:
  # when the session was created, and when it last billed an API call — the last
  # moment it demonstrably ran, which is what "at the end of the session" means
  # for a cost comparison. A session with no recorded usage falls back to its
  # creation time, which lands it cleanly in one cohort and contributes nothing
  # to any figure anyway.
  #
  # The last-call lookup is a LATERAL correlated to the row it is deciding, not a
  # grouped subquery over the whole ledger. An uncorrelated `GROUP BY session_id`
  # carries no qual from the outer WHERE, so Postgres would aggregate millions of
  # usage rows on every tick even when the anti-join below yields no candidates at
  # all. Correlated, it runs once per surviving session — none, at steady state —
  # and rides index_session_token_usages_on_session_id_and_called_at.
  def backfill(setting, cutoff)
    rows = SessionExperimentalFlag.connection.exec_update(
      SessionExperimentalFlag.sanitize_sql_array([ INSERT_SQL,
        {
          key: setting.key,
          landed_at: setting.landed_at,
          before: setting.value_before,
          after: setting.value_after,
          created_before: cutoff,
          source: SessionExperimentalFlag::BACKFILLED,
          now: Time.current
        } ])
    )

    Rails.logger.info("[ExperimentalFlagBackfillJob] #{setting.key}: labelled #{rows} session(s)") if rows.positive?
    rows
  end

  INSERT_SQL = <<~SQL
    INSERT INTO session_experimental_flags
      (session_id, setting_key, value_at_start, value_at_end, source,
       first_observed_at, last_observed_at, created_at, updated_at)
    SELECT
      s.id,
      :key,
      CASE WHEN s.created_at < :landed_at THEN :before ELSE :after END,
      CASE WHEN COALESCE(u.last_called_at, s.created_at) < :landed_at THEN :before ELSE :after END,
      :source,
      s.created_at,
      COALESCE(u.last_called_at, s.created_at),
      :now,
      :now
    FROM sessions s
    CROSS JOIN LATERAL (
      SELECT MAX(stu.called_at) AS last_called_at
      FROM session_token_usages stu
      WHERE stu.session_id = s.id
    ) u
    WHERE s.created_at < :created_before
      AND NOT EXISTS (
        SELECT 1 FROM session_experimental_flags f
        WHERE f.session_id = s.id AND f.setting_key = :key
      )
    ON CONFLICT (session_id, setting_key) DO NOTHING
  SQL
  private_constant :INSERT_SQL
end
