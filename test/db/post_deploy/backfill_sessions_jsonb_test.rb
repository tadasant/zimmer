# frozen_string_literal: true

require "test_helper"

# The half of #847's dual-write that the dual-write cannot do: rows that already
# existed when the shadow columns were added, and that nothing has written since.
# `ADD COLUMN` with no default writes no rows, so every one of them starts NULL
# and stays NULL until this task copies it.
class BackfillSessionsJsonbTest < ActiveSupport::TestCase
  COLUMNS = JsonbDualWrite::COLUMNS

  setup do
    @entry = PostDeployTask::Registry.find("20260905193500")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  def run_task(deadline: nil)
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = @task_class.new(run: run, deadline: deadline, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  # The state a production row is in the moment the migration lands: values in the
  # `json` columns, nothing in the shadows. Fixtures load by raw INSERT, so they
  # arrive this way already — this only makes it explicit and adds the columns the
  # fixtures leave blank.
  def unshadowed_session(**values)
    session = Session.create!(
      prompt: "backfill #{SecureRandom.hex(4)}",
      # Titled, so the `set_default_title` after_create does not stamp
      # `auto_generated_title` into the metadata these tests assert on.
      title: "backfill",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      **values
    )
    Session.where(id: session.id).update_all(COLUMNS.map { |c| "#{c}_jsonb = NULL" }.join(", "))
    session
  end

  def shadow_values(session)
    fresh = Session.find(session.id)
    COLUMNS.index_with { |name| fresh.read_attribute("#{name}_jsonb") }
  end

  test "copies every converted column into its shadow" do
    session = unshadowed_session(
      config: { "verbose" => true },
      mcp_servers: [ "context7" ],
      mcp_server_env: { "context7" => { "TOKEN" => "abc" } },
      mcp_server_headers: { "context7" => { "X-Trace" => "1" } },
      metadata: { "process_pid" => 4242 }
    )

    run, outcome = run_task

    assert_nil outcome, "a task that finishes returns something other than CONTINUE"
    assert_equal({
      "config" => { "verbose" => true },
      "mcp_servers" => [ "context7" ],
      "mcp_server_env" => { "context7" => { "TOKEN" => "abc" } },
      "mcp_server_headers" => { "context7" => { "X-Trace" => "1" } },
      "metadata" => { "process_pid" => 4242 }
    }, shadow_values(session))
    assert_operator run.stats.fetch("backfilled"), :>=, 1
  end

  test "leaves the source columns exactly as they were" do
    session = unshadowed_session(config: { "verbose" => true }, metadata: { "process_pid" => 7 })
    before = Session.find(session.id).attributes.slice(*COLUMNS)
    updated_at = Session.find(session.id).updated_at

    run_task

    assert_equal before, Session.find(session.id).attributes.slice(*COLUMNS)
    # A bulk copy that bumped `updated_at` would reorder every list in the UI and
    # misreport when each session last actually changed.
    assert_equal updated_at, Session.find(session.id).updated_at,
      "the backfill must not touch updated_at"
  end

  test "a NULL source stays NULL rather than becoming an empty object" do
    session = unshadowed_session(metadata: { "process_pid" => 1 })
    assert_nil Session.find(session.id).config

    run_task

    assert_nil Session.find(session.id).config_jsonb
  end

  # The mechanism never re-runs a task that succeeded, so this is the shape that
  # actually occurs: a slice died, the run is retried, and it walks rows it has
  # already copied. The cursor and the counters are reset first because they are
  # carried on the ledger row and would otherwise hide the predicate behind them.
  test "a re-run over rows it already copied copies nothing" do
    session = unshadowed_session(metadata: { "process_pid" => 1 })

    first_run, = run_task
    after_first = shadow_values(session)
    assert_operator first_run.stats.fetch("backfilled"), :>=, 1

    first_run.update!(cursor: {}, stats: {})
    second_run, outcome = run_task

    assert_nil outcome
    assert_equal after_first, shadow_values(session)
    assert_equal 0, second_run.stats.fetch("backfilled"),
      "the predicate must exclude a row it already copied"
  end

  # A session whose shadow the dual-write already filled is not stale data to be
  # overwritten from a snapshot — it is the current value. The predicate has to
  # leave it alone.
  test "does not disturb a row the dual-write already filled" do
    session = Session.create!(
      prompt: "already dual-written #{SecureRandom.hex(4)}",
      title: "already dual-written",
      agent_runtime: "claude_code", status: :waiting,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "process_pid" => 99 }
    )
    assert_equal({ "process_pid" => 99 }, Session.find(session.id).metadata_jsonb)

    run_task

    assert_equal({ "process_pid" => 99 }, Session.find(session.id).metadata_jsonb)
  end

  test "resumes from its cursor when the slice runs out of time" do
    3.times { |i| unshadowed_session(metadata: { "process_pid" => i }) }

    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    # A deadline already in the past: `sweep` checks the budget after each batch,
    # so one batch lands and the task yields.
    outcome = @task_class.new(run: run, deadline: 1.minute.ago, logger: Rails.logger).up

    assert_equal PostDeployTask::CONTINUE, outcome
    assert run.reload.cursor["sweep_last_id"].present?, "the cursor has to carry where to resume"

    # The resumed run — same ledger row, same cursor — finishes the rest.
    assert_nil @task_class.new(run: run, logger: Rails.logger).up
    assert_equal 0, Session.where(@task_class::PENDING).count
  end

  test "leaves nothing pending across the whole table" do
    unshadowed_session(config: { "a" => 1 }, metadata: { "b" => 2 })
    Session.where(id: sessions(:running).id).update_all(COLUMNS.map { |c| "#{c}_jsonb = NULL" }.join(", "))

    run_task

    assert_equal 0, Session.where(@task_class::PENDING).count,
      "every row with a value to copy must have been copied"
  end

  # `transcript` is deliberately not part of the conversion — it is the column
  # that makes an in-place ALTER dangerous and the one that gains nothing.
  test "does not touch transcript" do
    assert_not @task_class::COLUMNS.include?("transcript")
    assert_not Session.column_names.include?("transcript_jsonb")
  end
end
