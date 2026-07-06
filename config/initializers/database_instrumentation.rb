# Instrument database queries to surface slow operations in the logs.
#
# `sql.active_record` is delivered AFTER the query returns, so every line this
# emits describes a query that already COMPLETED — it is a passive diagnostic
# of a successful-but-slow query, never a failed operation with something to
# retry. A slow query can stem from lock contention OR from host/DB saturation
# (CPU, IO, connection pool); the subscriber cannot tell which from duration
# alone, so it reports the duration and names both possibilities rather than
# asserting a specific cause.
#
# Levels follow the repo logging philosophy (see CLAUDE.md):
#   >1s  -> .warn  [DatabaseSlow]  : an edge case worth knowing about.
#   >5s  -> .warn  [DatabaseChoke] : rarer and worse, but still a transient,
#           self-resolving blip — not a "should never happen" error. A single
#           slow query that has already recovered must NOT page the production
#           ERROR alert (rules-ao-errors.yaml fires on any single
#           severity_text:ERROR line). Sustained saturation that actually
#           breaks things surfaces as real ERROR lines (failed jobs/requests)
#           which still page; and it is better caught at the host/DB level by
#           infra alerts at the right altitude. Both lines stay queryable in
#           VictoriaLogs for investigation and dashboards.
#
# See issue #4403 for the incident that motivated the wording correction and
# the ERROR -> WARN downgrade (recommendations #2 and #3).
module DatabaseInstrumentation
  SLOW_THRESHOLD_MS = 1000
  CHOKE_THRESHOLD_MS = 5000
  SQL_MAX_LEN = 200

  # Logs a single line for a completed query if it exceeded the slow threshold.
  # Choke (>5s) and Slow (1-5s) are mutually exclusive so a single slow query
  # produces exactly one line, never a duplicated pair.
  def self.log_slow_query(duration_ms, sql)
    return if duration_ms <= SLOW_THRESHOLD_MS

    sql_truncated = sql.length > SQL_MAX_LEN ? "#{sql[0, SQL_MAX_LEN]}..." : sql
    # .round (no arg) returns an Integer; the subscriber feeds a Float duration,
    # so this keeps the rendered line as "6201ms", not "6201.0ms".
    rounded = duration_ms.round

    if duration_ms > CHOKE_THRESHOLD_MS
      Rails.logger.warn "[DatabaseChoke] Query took #{rounded}ms (lock contention or DB/host saturation; query completed): #{sql_truncated}"
    else
      Rails.logger.warn "[DatabaseSlow] Query took #{rounded}ms: #{sql_truncated}"
    end
  end
end

ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, start, finish, _id, payload|
  duration_ms = (finish - start) * 1000
  DatabaseInstrumentation.log_slow_query(duration_ms, payload[:sql])
end
