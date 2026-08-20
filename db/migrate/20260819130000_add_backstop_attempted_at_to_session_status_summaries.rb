# frozen_string_literal: true

# When StatusSummaryBackstopJob last examined this session's summary.
#
# The sweep needs a stamp that moves whatever the outcome, including the runs
# that decide nothing needs repairing and the ones the generator refuses without
# writing anything (a session whose clone has been reclaimed is refused before a
# record is touched). Without it, a healthy session is re-measured against its
# whole transcript every five minutes, and a session that can never be
# summarized eats the sweep's per-run cap ahead of ones that could be repaired.
class AddBackstopAttemptedAtToSessionStatusSummaries < ActiveRecord::Migration[8.0]
  def change
    add_column :session_status_summaries, :backstop_attempted_at, :datetime
  end
end
