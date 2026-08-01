# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260801120000_backfill_renamed_open_pr_skill_id")

# The runtime self-heal only fires the next time a row is used, and it drops the
# unknown id rather than repointing it. This migration is what actually carries
# existing rows across the `pr` → `open-pr` rename, so its SQL is worth pinning:
# it rewrites both tables, leaves unrelated ids alone, and can't duplicate an id.
class BackfillRenamedOpenPrSkillIdTest < ActiveSupport::TestCase
  setup do
    @migration = BackfillRenamedOpenPrSkillId.new
    @migration.verbose = false
    @session = sessions(:active_session)
    @trigger = triggers(:enabled_schedule_trigger)
  end

  test "repoints the renamed skill id on sessions and triggers, preserving order" do
    @session.update_column(:catalog_skills, [ "zimmer-run-tests", "pr", "sync-docs" ])
    @trigger.update_column(:catalog_skills, [ "pr" ])

    @migration.up

    assert_equal [ "zimmer-run-tests", "open-pr", "sync-docs" ], @session.reload.catalog_skills
    assert_equal [ "open-pr" ], @trigger.reload.catalog_skills
  end

  test "leaves rows without the renamed id untouched" do
    @session.update_column(:catalog_skills, [ "zimmer-run-tests" ])
    @trigger.update_column(:catalog_skills, [])

    @migration.up

    assert_equal [ "zimmer-run-tests" ], @session.reload.catalog_skills
    assert_equal [], @trigger.reload.catalog_skills
  end

  test "does not duplicate when a row already carries both ids" do
    @session.update_column(:catalog_skills, [ "pr", "open-pr" ])

    @migration.up

    assert_equal [ "open-pr" ], @session.reload.catalog_skills
  end

  test "down repoints the id back" do
    @session.update_column(:catalog_skills, [ "open-pr", "sync-docs" ])

    @migration.down

    assert_equal [ "pr", "sync-docs" ], @session.reload.catalog_skills
  end
end
