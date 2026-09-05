# frozen_string_literal: true

require "test_helper"

# The forward-only half of #731: `Session.locate` reads an all-digit identifier
# as an id and `slug_is_not_purely_numeric` refuses to write a new one, so a row
# that already holds such a slug is the one case where the consolidation makes a
# reachable answer worse. This is the repair.
class RepairPurelyNumericSessionSlugsTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260905180000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  def session(slug: nil, created_at: Time.zone.parse("2026-08-30 11:02"))
    record = Session.create!(prompt: "slug #{SecureRandom.hex(4)}", agent_runtime: "claude_code",
                             status: :waiting, git_root: "https://github.com/test/repo.git", branch: "main",
                             execution_provider: "local_filesystem")
    # update_columns, because writing an all-digit slug is exactly what the model
    # now refuses — the rows this task exists for predate that validation.
    record.update_columns(slug: slug, created_at: created_at) if slug
    record.reload
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  test "renames an all-digit slug to the stamped form, and leaves every other slug alone" do
    numeric = session(slug: "728")
    digit_prefixed = session(slug: "728-fix-the-poller-20260830-1102")
    ordinary = session(slug: "ship-it-20260830-1102")

    run, outcome = run_task

    assert_nil outcome, "a task that finishes returns something other than CONTINUE"
    assert_equal "728-20260830-1102", numeric.reload.slug
    assert_equal "728-fix-the-poller-20260830-1102", digit_prefixed.reload.slug
    assert_equal "ship-it-20260830-1102", ordinary.reload.slug
    assert_equal 1, run.stats["rows_renamed"]
    assert_equal 0, run.stats["rows_skipped"]
  end

  test "the renamed session is reachable by its new slug, and no longer shadows a session id" do
    numeric = session(slug: "728")

    run_task

    assert_equal numeric, Session.locate("728-20260830-1102")
    assert_nil Session.locate("728"), "the id 728 is nobody's here, and the slug no longer answers for it"
  end

  test "suffixes past a slug another session already holds" do
    session(slug: "728-20260830-1102")
    numeric = session(slug: "728")

    run_task

    assert_equal "728-20260830-1102-1", numeric.reload.slug
  end

  # `rows_renamed` is cumulative across resumptions of one ledger row, so the
  # second run holding it at 1 is the assertion: it renamed nothing further.
  test "is idempotent — a second run renames nothing, because a repaired row no longer matches" do
    numeric = session(slug: "728")

    run_task
    renamed = numeric.reload.slug

    run, outcome = run_task

    assert_nil outcome
    assert_equal renamed, numeric.reload.slug
    assert_equal 1, run.stats["rows_renamed"]
    assert_empty Session.where("slug ~ '^[0-9]+$'")
  end

  test "reports zero rather than silence when there is nothing to repair" do
    session(slug: "ship-it-20260830-1102")

    run, outcome = run_task

    assert_nil outcome
    assert_equal 0, run.stats["rows_renamed"]
    assert_equal 0, run.stats["rows_skipped"]
  end
end
