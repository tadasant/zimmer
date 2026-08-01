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
    @session = sessions(:active_session)
    @trigger = triggers(:enabled_schedule_trigger)
  end

  # suppress_messages rather than `verbose = false`: verbose is a cattr, so the
  # writer would silence migration logging for the rest of the worker process.
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { @migration.public_send(direction) }
  end

  test "repoints the renamed skill id on sessions and triggers, preserving order" do
    @session.update_column(:catalog_skills, [ "zimmer-run-tests", "pr", "sync-docs" ])
    @trigger.update_column(:catalog_skills, [ "pr" ])

    migrate(:up)

    assert_equal [ "zimmer-run-tests", "open-pr", "sync-docs" ], @session.reload.catalog_skills
    assert_equal [ "open-pr" ], @trigger.reload.catalog_skills
  end

  test "leaves rows without the renamed id untouched" do
    @session.update_column(:catalog_skills, [ "zimmer-run-tests" ])
    @trigger.update_column(:catalog_skills, [])

    migrate(:up)

    assert_equal [ "zimmer-run-tests" ], @session.reload.catalog_skills
    assert_equal [], @trigger.reload.catalog_skills
  end

  test "does not duplicate when a row already carries both ids" do
    @session.update_column(:catalog_skills, [ "pr", "open-pr" ])

    migrate(:up)

    assert_equal [ "open-pr" ], @session.reload.catalog_skills
  end

  test "leaves a NULL catalog_skills column alone" do
    # sessions.catalog_skills is nullable, and jsonb_array_elements(NULL) would
    # be a per-row error rather than a no-op if the containment filter let it
    # through. It doesn't: NULL @> '["pr"]' is NULL, so the row never matches.
    @session.update_column(:catalog_skills, nil)

    migrate(:up)

    assert_nil @session.reload.catalog_skills
  end

  test "down repoints the id back on sessions and triggers" do
    @session.update_column(:catalog_skills, [ "open-pr", "sync-docs" ])
    @trigger.update_column(:catalog_skills, [ "open-pr" ])

    migrate(:down)

    assert_equal [ "pr", "sync-docs" ], @session.reload.catalog_skills
    assert_equal [ "pr" ], @trigger.reload.catalog_skills
  end
end
