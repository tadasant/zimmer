# How many sessions were actively burning quota when a quota reading was taken.
#
# The usage-rate metric divides utilization consumed by *session-hours*, and the
# session count at each sample is the only way to reconstruct that denominator
# after the fact — session status is mutable and carries no history. Recording it
# on the snapshot row makes each reading self-describing.
#
# Nullable: every row written before this migration has no count, and the rate
# service skips sample pairs it cannot attribute rather than guessing.
class AddActiveSessionCountToQuotaSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :claude_account_quota_snapshots, :active_session_count, :integer
  end
end
