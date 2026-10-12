# frozen_string_literal: true

# Teaches the planner how many groups CostAnalytics' rollups actually produce.
#
# Postgres estimates the group count of `GROUP BY date(called_at), agent_root,
# model` by multiplying each column's distinct count, assumes they are
# independent, and lands near one group per row — hundreds of thousands, for a
# rollup that has a few thousand. On that estimate it sorts every row of the
# window on disk instead of hashing them in memory, which makes it the slowest
# single query in a long-window cost report. Multivariate ndistinct statistics give
# it the real count, and the plan becomes a HashAggregate.
#
# `CREATE STATISTICS` is not something schema.rb can express, so these objects
# exist only where this migration ran: production and any database migrated
# forward. A database loaded from schema.rb (CI, `db:prepare` on a fresh clone)
# answers the same queries with the same figures, just on the slower plan.
class AddCostRollupStatisticsToSessionTokenUsages < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE STATISTICS IF NOT EXISTS session_token_usages_day_root_model (ndistinct)
        ON (date(called_at)), agent_root, model FROM session_token_usages
    SQL
    execute <<~SQL
      CREATE STATISTICS IF NOT EXISTS session_token_usages_session_root_model (ndistinct)
        ON session_id, agent_root, model FROM session_token_usages
    SQL
    # Statistics objects are empty until the table is analyzed. ANALYZE samples a
    # fixed number of rows, so this is quick at any table size.
    execute "ANALYZE session_token_usages"
  end

  def down
    execute "DROP STATISTICS IF EXISTS session_token_usages_day_root_model"
    execute "DROP STATISTICS IF EXISTS session_token_usages_session_root_model"
  end
end
