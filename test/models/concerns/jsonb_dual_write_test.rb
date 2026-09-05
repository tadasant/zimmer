# frozen_string_literal: true

require "test_helper"

# The dual-write window of #847, from the only angle that can actually catch it
# going wrong.
#
# Nothing reads a `_jsonb` column yet, so a writer that fills `metadata` and skips
# `metadata_jsonb` breaks NOTHING today — no test fails, no page misrenders, no
# log line appears — and turns into data loss the moment PR 2 swaps the readers
# over. So every test here asserts the same thing about a different writer: after
# the write, and read back FROM THE DATABASE rather than from the object that did
# it, the two columns agree.
class JsonbDualWriteTest < ActiveSupport::TestCase
  # Read the row again rather than trusting the instance under test: an in-memory
  # attribute that agrees with its twin proves only that this object is
  # self-consistent, which is exactly the thing that stays true when the SQL
  # forgot the second column.
  def assert_columns_agree(session, *names, context: nil)
    names = JsonbDualWrite::COLUMNS if names.empty?
    fresh = Session.find(session.id)

    names.map(&:to_s).each do |name|
      message = [ context, "sessions.#{name} and sessions.#{name}_jsonb disagree on session #{session.id}" ]
        .compact.join(": ")
      source = fresh.read_attribute(name)

      # `assert_nil` rather than `assert_equal nil` — minitest refuses the latter,
      # and a NULL source is a case that genuinely occurs (`config` is unset on
      # most sessions), so it has to be asserted rather than skipped.
      if source.nil?
        assert_nil fresh.read_attribute("#{name}_jsonb"), message
      else
        assert_equal source, fresh.read_attribute("#{name}_jsonb"), message
      end
    end
  end

  # Titled by default. An untitled session gets `metadata["auto_generated_title"]`
  # stamped on it by an `after_create` that writes through `update_columns`, which
  # is a genuine writer and has a test of its own below — but it is noise in every
  # test that is about something else.
  def build_session(**attrs)
    Session.new({
      prompt: "dual write #{SecureRandom.hex(4)}",
      title: "dual write",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }.merge(attrs))
  end

  test "Session.create! fills every shadow column" do
    session = build_session(
      config: { "verbose" => true },
      mcp_servers: [ "context7" ],
      mcp_server_env: { "context7" => { "TOKEN" => "abc" } },
      mcp_server_headers: { "context7" => { "X-Trace" => "1" } },
      metadata: { "process_pid" => 4242 }
    )
    session.save!

    assert_columns_agree(session, context: "after create!")
    assert_equal({ "verbose" => true }, Session.find(session.id).config_jsonb)
    assert_equal([ "context7" ], Session.find(session.id).mcp_servers_jsonb)
  end

  # The create path cannot lean on dirty tracking: an INSERT writes every column
  # whether or not the caller assigned it, and `metadata` arrives from a schema
  # default nobody touched.
  test "a create that assigns nothing still fills the shadows with what it stored" do
    session = build_session
    session.save!

    assert_columns_agree(session, context: "after a bare create!")
    assert_equal({}, Session.find(session.id).metadata_jsonb,
      "metadata's schema default has to reach the shadow too")
    assert_nil Session.find(session.id).config_jsonb, "a NULL source stays NULL, not {}"
  end

  # The writer that actually bit. `set_default_title` is an `after_create` that
  # stamps `metadata["auto_generated_title"]` through `update_columns`, which skips
  # every callback — so before the override in JsonbDualWrite it reached `metadata`
  # and not its shadow on EVERY session created without a title, which is nearly
  # all of them. `touch_user_view!` is the same shape on every page view.
  test "an untitled create carries the flag its after_create stamps into the shadow" do
    session = build_session(title: nil)
    session.save!

    assert_columns_agree(session, :metadata, context: "after an untitled create!")
    assert_equal true, Session.find(session.id).metadata_jsonb["auto_generated_title"]
  end

  test "update_column mirrors into the shadow even though it skips callbacks" do
    session = build_session(metadata: { "process_pid" => 1 })
    session.save!

    session.touch_user_view!

    assert_columns_agree(session, :metadata, context: "after touch_user_view!")
    assert Session.find(session.id).metadata_jsonb["last_user_activity_at"].present?
    assert_equal 1, Session.find(session.id).metadata_jsonb["process_pid"]
  end

  test "update_columns leaves an unconverted column alone" do
    session = build_session
    session.save!

    session.update_columns(running_job_id: "job-123")

    assert_equal "job-123", Session.find(session.id).running_job_id
    assert_columns_agree(session, context: "after writing an unconverted column")
  end

  test "update! carries the column it changed into the shadow" do
    session = sessions(:running)

    session.update!(metadata: { "clone_path" => "/clones/abc" })
    assert_columns_agree(session, :metadata, context: "after update!")

    session.update!(mcp_servers: [ "playwright-custom" ], config: { "model" => "opus" })
    assert_columns_agree(session, :metadata, :mcp_servers, :config, context: "after a second update!")
  end

  test "a save that changes nothing JSON-shaped leaves the shadows where they were" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 1 })

    session.update!(title: "renamed")

    assert_columns_agree(session, :metadata, context: "after an unrelated update!")
    assert_equal({ "process_pid" => 1 }, Session.find(session.id).metadata_jsonb)
  end

  test "merge_metadata! writes both columns in its one statement" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111 })

    session.merge_metadata!("interrupt_terminate_pid" => 4242)

    assert_columns_agree(session, :metadata, context: "after merge_metadata!")
    assert_equal({ "process_pid" => 111, "interrupt_terminate_pid" => 4242 },
      Session.find(session.id).metadata_jsonb)
  end

  test "remove_metadata! drops the key from both columns" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111, "sigterm_retry_count" => 2 })

    session.remove_metadata!("sigterm_retry_count")

    assert_columns_agree(session, :metadata, context: "after remove_metadata!")
    assert_equal({ "process_pid" => 111 }, Session.find(session.id).metadata_jsonb)
  end

  # The merge starts from a row whose shadow the backfill has not reached yet —
  # fixtures are raw INSERTs, so they arrive with every shadow NULL, exactly like
  # a production row on the morning of the deploy.
  test "merge_metadata! fills a shadow that was still NULL" do
    session = sessions(:running)
    Session.where(id: session.id).update_all("metadata_jsonb = NULL")

    session.merge_metadata!("clone_path" => "/clones/def")

    assert_columns_agree(session, :metadata, context: "merging onto a NULL shadow")
    assert_equal "/clones/def", Session.find(session.id).metadata_jsonb["clone_path"]
  end

  # The sharpest edge in the SQL change: the merge expression is interpolated
  # twice and its binds are supplied twice, so a placeholder and a bind that fell
  # out of step would put the removals of one assignment against the updates of
  # the other. Only a merge that BOTH removes and adds can catch that.
  test "a merge that removes and adds in one statement binds both assignments in step" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111, "sigterm_retry_count" => 2 })

    session.merge_metadata!({ "clone_path" => "/clones/ghi" }, [ "sigterm_retry_count" ])

    assert_columns_agree(session, :metadata, context: "after a combined merge and remove")
    assert_equal({ "process_pid" => 111, "clone_path" => "/clones/ghi" },
      Session.find(session.id).metadata_jsonb)
  end

  # The twin assignment reads the SOURCE column, not the shadow, so a shadow that
  # is wrong rather than merely absent is corrected by the next merge. That
  # self-healing is what limits the blast radius of the rolling-deploy window the
  # backfill's predicate is written for.
  test "a merge repairs a shadow that is stale rather than NULL" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111 })
    Session.where(id: session.id).update_all("metadata_jsonb = '{\"stale\": true}'::jsonb")

    session.merge_metadata!("clone_path" => "/clones/jkl")

    assert_columns_agree(session, :metadata, context: "merging onto a stale shadow")
    assert_equal({ "process_pid" => 111, "clone_path" => "/clones/jkl" },
      Session.find(session.id).metadata_jsonb)
  end

  # A partially-selected record carries no shadow attribute. Merging on one does
  # raise — on `status`, from `broadcast_update_to_sessions_index`, which is
  # pre-existing code this change does not touch — and the point of asserting on
  # the attribute NAME is that the failure is not, and must never become, one the
  # dual-write introduced on the app's hottest write path. The row gets both
  # columns regardless, because the UPDATE names them whatever this object holds.
  test "the dual-write adds no failure mode to a partially selected record" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111 })

    partial = Session.select(:id, :metadata).find(session.id)
    assert_not partial.has_attribute?("metadata_jsonb")

    error = assert_raises(ActiveModel::MissingAttributeError) do
      partial.merge_metadata!("interrupt_terminate_pid" => 4242)
    end
    assert_match(/status/, error.message)
    assert_no_match(/metadata_jsonb/, error.message)

    assert_columns_agree(session, :metadata, context: "after merging a partial select")
    assert_equal 4242, Session.find(session.id).metadata_jsonb["interrupt_terminate_pid"]
  end

  test "a merge on a stale object does not resurrect the shadow it was loaded with" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111 })
    stale = Session.find(session.id)

    Session.find(session.id).merge_metadata!("interrupt_terminate_pid" => 4242)
    stale.merge_metadata!("job_started_at" => "2026-01-01T00:00:00Z")

    assert_columns_agree(session, :metadata, context: "after two interleaved merges")
    assert_equal({ "process_pid" => 111, "interrupt_terminate_pid" => 4242,
                   "job_started_at" => "2026-01-01T00:00:00Z" },
      Session.find(session.id).metadata_jsonb)
  end

  # The merge is a raw UPDATE, so the object it was called on has to be told what
  # landed — for BOTH columns. If the shadow attribute kept the value this object
  # was loaded with, the next ordinary `save` on the same object would write that
  # stale value back over the merge.
  test "a save after a merge does not push a stale shadow back over it" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111 })

    session.merge_metadata!("interrupt_terminate_pid" => 4242)
    session.update!(title: "still here")

    assert_columns_agree(session, :metadata, context: "after merge then save")
    assert_equal({ "process_pid" => 111, "interrupt_terminate_pid" => 4242 },
      Session.find(session.id).metadata_jsonb)
  end

  # `custom_metadata` is already jsonb and has no shadow. The merge has to notice
  # that rather than generating SQL naming a `custom_metadata_jsonb` that is not
  # there.
  test "merging custom_metadata touches no shadow column" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 111 })

    session.merge_custom_metadata!("mcp_servers_status" => { "context7" => "ok" })

    assert_equal({ "context7" => "ok" },
      Session.find(session.id).custom_metadata["mcp_servers_status"])
    assert_columns_agree(session, :metadata, context: "after merging the unshadowed column")
    assert_not Session.column_names.include?("custom_metadata_jsonb"),
      "custom_metadata has been jsonb from the start; giving it a shadow would be the bug"
  end

  test "twin_for answers only for the columns being converted" do
    assert_equal "metadata_jsonb", JsonbDualWrite.twin_for(Session, "metadata")
    assert_equal "config_jsonb", JsonbDualWrite.twin_for(Session, :config)
    assert_nil JsonbDualWrite.twin_for(Session, "custom_metadata")
    assert_nil JsonbDualWrite.twin_for(Session, "transcript"),
      "transcript is deliberately staying json — see the migration"
  end

  test "transcript is not shadowed" do
    assert_not Session.column_names.include?("transcript_jsonb")
    assert_equal "json", Session.columns_hash["transcript"].sql_type
  end

  # The state machine, the transcript poller and the interrupt service all reach
  # the columns through the same two paths above, so one end-to-end pass over a
  # real lifecycle is worth more than a mock of each: it is the shape that would
  # catch a writer nobody thought to enumerate.
  test "a session driven through its lifecycle keeps both columns in step" do
    session = build_session(metadata: { "process_pid" => 1 })
    session.save!

    session.merge_metadata!("job_started_at" => "2026-01-01T00:00:00Z")
    session.start!
    session.update!(mcp_servers: [ "context7" ])
    session.merge_metadata!("clone_path" => "/clones/xyz")
    session.pause!
    session.remove_metadata!("process_pid")

    assert_columns_agree(session, context: "after a full lifecycle")
    assert_equal({ "job_started_at" => "2026-01-01T00:00:00Z", "clone_path" => "/clones/xyz" },
      Session.find(session.id).metadata_jsonb)
  end
end
