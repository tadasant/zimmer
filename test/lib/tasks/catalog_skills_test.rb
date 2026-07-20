# frozen_string_literal: true

require "test_helper"
require "rake"

# The operator sweep that clears stale catalog skill ids from stored session
# config. It performs a bulk, irreversible write across every non-archived
# session, so its two refusal guards matter as much as its happy path: an empty
# catalog makes every id look stale, and a degraded (last-known-good) catalog can
# be missing ids that were added after the snapshot was taken.
class CatalogSkillsTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Session.destroy_all
  end

  teardown do
    Rake::Task.clear
    ENV.delete("DRY_RUN")
  end

  def session_with_skills(skills, status: "needs_input")
    session = Session.create!(
      prompt: "Test",
      status: status,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      catalog_skills: [ "zimmer-run-tests" ]
    )
    # update_column plants ids past the create-time validation, exactly the way a
    # catalog that changed after the session was saved leaves them.
    session.update_column(:catalog_skills, skills)
    session
  end

  def run_sweep
    Rake::Task["sessions:heal_stale_catalog_skills"].reenable
    capture_io { Rake::Task["sessions:heal_stale_catalog_skills"].invoke }
  end

  test "removes stale ids and leaves catalog-resident ones untouched" do
    stale = session_with_skills([ "zimmer-run-tests", "renamed-away-skill" ])
    clean = session_with_skills([ "zimmer-run-tests" ])

    run_sweep

    assert_equal [ "zimmer-run-tests" ], stale.reload.catalog_skills
    assert_equal [ "zimmer-run-tests" ], clean.reload.catalog_skills
  end

  test "DRY_RUN reports without writing" do
    stale = session_with_skills([ "zimmer-run-tests", "renamed-away-skill" ])
    ENV["DRY_RUN"] = "true"

    out, _err = run_sweep

    assert_equal [ "zimmer-run-tests", "renamed-away-skill" ], stale.reload.catalog_skills,
      "DRY_RUN must not write"
    assert_match(/renamed-away-skill/, out)
    assert_match(/DRY RUN/, out)
  end

  test "skips archived sessions" do
    archived = session_with_skills([ "zimmer-run-tests", "renamed-away-skill" ], status: "archived")

    run_sweep

    assert_equal [ "zimmer-run-tests", "renamed-away-skill" ], archived.reload.catalog_skills,
      "an archived session can't resume, so it can't re-alert — leave its record as history"
  end

  test "refuses to run when the catalog is empty" do
    stale = session_with_skills([ "zimmer-run-tests", "renamed-away-skill" ])
    SkillsConfig.stubs(:all).returns([])

    assert_raises(SystemExit) { run_sweep }

    assert_equal [ "zimmer-run-tests", "renamed-away-skill" ], stale.reload.catalog_skills,
      "an empty catalog makes every id look stale — a sweep would strip everything"
  end

  test "refuses to run when the catalog is degraded" do
    stale = session_with_skills([ "zimmer-run-tests", "renamed-away-skill" ])
    AirCatalogService.stubs(:degraded?).returns(true)

    assert_raises(SystemExit) { run_sweep }

    assert_equal [ "zimmer-run-tests", "renamed-away-skill" ], stale.reload.catalog_skills,
      "a last-known-good snapshot can be missing ids added since it was taken"
  end
end
