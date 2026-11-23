# frozen_string_literal: true

require "time"

class RetryBudget
  # What every session has spent of every budget, from ONE pass over `sessions`.
  #
  # The keys live in `sessions.metadata` with no index, so each question asked of the
  # table is a sequential scan that de-TOASTs every row, and there are four a budget. One
  # scan fetches the rows carrying any of the keys; the arithmetic is done in Ruby over
  # what comes back. Pulling the keys out with `jsonb_each` reads each row's metadata
  # once rather than once per key.
  #
  # Values are read leniently for the reason RetryBudget#last_attempt_at is: metadata is
  # not schema-checked, and one corrupt value must not take the health page down.
  class Usage
    # Stamped on a session that ran into its account's quota. Not a budget, but the health
    # report counts it and it costs nothing in the same pass.
    QUOTA_STAMP = "last_quota_limit_at"

    Row = Struct.new(:id, :status, :values)

    def initialize(budgets: RetryBudget.all)
      @rows = load_rows(budgets)
    end

    # @return [Hash] :total_sessions, :total_retries_attempted, :recovered, :exhausted, and
    #   :recent — the ids of sessions whose last attempt is newer than +since+, newest first
    def for(budget, since:)
      counted = @rows.reject { |row| row.values[budget.key].nil? }
      ended, others = counted.partition { |row| row.status == budget.terminal_status.to_s }
      recent = attempts_since(budget.stamp, since)

      {
        total_sessions: counted.size,
        total_retries_attempted: counted.sum { |row| count_of(row, budget) },
        recovered: others.count { |row| row.status.present? },
        exhausted: ended.count { |row| count_of(row, budget) >= budget.max },
        recent: recent.sort_by { |_id, at| at }.reverse.map(&:first)
      }
    end

    def quota_limited_count
      @rows.count { |row| !row.values[QUOTA_STAMP].nil? }
    end

    def quota_limited_count_since(since)
      attempts_since(QUOTA_STAMP, since).size
    end

    private

    def load_rows(budgets)
      keys = (budgets.flat_map { |budget| [ budget.key, budget.stamp ] } << QUOTA_STAMP).uniq
      carried = Session.sanitize_sql_array([ <<~SQL.squish, keys ])
        CASE WHEN jsonb_typeof(sessions.metadata) = 'object' THEN (
          SELECT jsonb_object_agg(entry.key, entry.value)
          FROM jsonb_each(sessions.metadata) entry WHERE entry.key IN (?)
        ) END
      SQL

      # `jsonb_exists_any` is the function behind `?|`, spelled without the `?` that
      # ActiveRecord would take for a bind.
      Session.where("jsonb_exists_any(sessions.metadata, ARRAY[:keys])", keys: keys)
        .pluck(:id, :status, Arel.sql(carried))
        .map { |id, status, values| Row.new(id, status.to_s, parsed(values)) }
    end

    def parsed(values)
      values = JSON.parse(values) if values.is_a?(String)
      values || {}
    end

    def count_of(row, budget)
      row.values[budget.key].to_s.to_i
    end

    # [[session id, Time]] for every row stamped after +since+.
    def attempts_since(stamp, since)
      @rows.filter_map do |row|
        at = time_of(row.values[stamp])
        [ row.id, at ] if at && at > since
      end
    end

    def time_of(raw)
      raw.blank? ? nil : Time.parse(raw.to_s)
    rescue ArgumentError
      nil
    end
  end
end
