# frozen_string_literal: true

# When a stranded-rows page last covered this row (#1592). The liveness sweep
# pages on new information, and "a page has already told someone about this row"
# is the memory that makes it new: see WorkBacklog::LivenessSweep#alert_if_overdue.
# It replaces a severity band kept in Redis that re-paged every week band.
#
# THE BACKFILL. Every unheld row that is stranded today has already been paged
# for by the band this replaces: that band paged whenever the oldest row was
# overdue and nothing was remembered, and it re-paged at least weekly. Left
# NULL, the first pass after the deploy would page the whole standing
# population once more as "new", which is the noise #1592 is about. So the
# rows in a stranded verdict are stamped with now.
#
# The stamp cannot silence a row that was never paged. A row counts as covered
# only by a page sent while it was overdue (`ALERT_AFTER` past the moment it left
# the queue), so a row stranded for less than that when this runs still pages
# when it gets there. Held rows are left NULL: a hold that lapses on a row no page
# covered pages on the lapse, which is the conservative reading when nothing
# says whether the old band covered it. Every other row a stamp lands on wrongly
# is cleared by the first pass, which forgets the mark on any row that has left
# the unresolved set.
class AddStrandedPagedAtToWorkBacklogItems < ActiveRecord::Migration[8.1]
  STRANDED_VERDICTS = %w[pr_stalled pr_merged_issue_open no_pr unknown].freeze

  def up
    add_column :work_backlog_items, :stranded_paged_at, :datetime

    execute(<<~SQL.squish)
      UPDATE work_backlog_items
         SET stranded_paged_at = now()
       WHERE status IN ('started', 'removed')
         AND liveness_state IN (#{STRANDED_VERDICTS.map { |verdict| connection.quote(verdict) }.join(', ')})
         AND (held_until IS NULL OR held_until <= now())
    SQL
  end

  def down
    remove_column :work_backlog_items, :stranded_paged_at
  end
end
