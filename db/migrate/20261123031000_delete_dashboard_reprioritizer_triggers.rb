# frozen_string_literal: true

# The dashboard's Reprioritize button is gone, and with it the code that created
# the "Dashboard reprioritizer" trigger on first press and re-created it whenever
# it was missing. The row that code left behind names the `dashboard-reprioritizer`
# agent root, which the catalog drops next; a trigger naming a root that does not
# exist would fail on its next fire. Nothing fires it any more, so it goes.
#
# Matched on either the name the code gave it or the root it named, so a row an
# operator renamed is caught too. Its conditions go first (that foreign key does
# not cascade); every other table pointing at a trigger cascades or nullifies.
# Idempotent: a second run matches nothing.
class DeleteDashboardReprioritizerTriggers < ActiveRecord::Migration[8.1]
  MATCH = <<~SQL.squish
    SELECT id FROM triggers
    WHERE name = 'Dashboard reprioritizer' OR agent_root_name = 'dashboard-reprioritizer'
  SQL

  def up
    execute("DELETE FROM trigger_conditions WHERE trigger_id IN (#{MATCH})")
    execute("DELETE FROM triggers WHERE id IN (#{MATCH})")
  end

  # Nothing to restore: no code reads or creates the trigger any more.
  def down; end
end
