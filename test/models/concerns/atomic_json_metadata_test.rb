require "test_helper"
require "mocha/minitest"

# Every test here is a lost-update scenario: one writer holds a snapshot of the row
# taken BEFORE another writer set a key, then writes. The old whole-column
# read-modify-write erased the other writer's key; the jsonb merge does not.
#
# The interleaving is expressed with two ActiveRecord objects pointing at the same row
# rather than with threads, so it is deterministic — the stale object IS the snapshot a
# long-lived job holds across a poll cycle or a monitoring-loop iteration.
class AtomicJsonMetadataTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @session.update!(metadata: { "process_pid" => 111 }, custom_metadata: {})
  end

  # Pins the hazard the concern exists to fix, so the guarantees below are measured
  # against something real rather than asserted in a vacuum. If this ever stops failing
  # to preserve the key, the `metadata:` column stopped being a whole-column write and
  # the rest of this file is testing nothing.
  test "the whole-column read-modify-write this replaces loses a concurrent writer's key" do
    stale = Session.find(@session.id)

    Session.find(@session.id).merge_metadata!("interrupt_terminate_pid" => 4242)
    stale.update!(metadata: (stale.metadata || {}).merge("job_started_at" => "2026-01-01T00:00:00Z"))

    assert_nil @session.reload.metadata["interrupt_terminate_pid"],
      "expected the read-modify-write shape to erase the concurrently-set key"
  end

  test "merge_metadata! keeps a key set after this object was loaded" do
    stale = Session.find(@session.id)

    Session.find(@session.id).merge_metadata!("interrupt_terminate_pid" => 4242)
    stale.merge_metadata!("job_started_at" => "2026-01-01T00:00:00Z")

    @session.reload
    assert_equal 4242, @session.metadata["interrupt_terminate_pid"]
    assert_equal "2026-01-01T00:00:00Z", @session.metadata["job_started_at"]
    assert_equal 111, @session.metadata["process_pid"], "untouched keys must survive"
  end

  test "remove_metadata! removes only the named keys, leaving a concurrent writer's alone" do
    @session.update!(metadata: { "process_pid" => 111, "sigterm_retry_count" => 2 })
    stale = Session.find(@session.id)

    Session.find(@session.id).merge_metadata!("pending_follow_up_prompt" => "please fix the test")
    stale.remove_metadata!(Session::SIGTERM_RETRY_METADATA_KEYS)

    @session.reload
    assert_equal "please fix the test", @session.metadata["pending_follow_up_prompt"]
    assert_nil @session.metadata["sigterm_retry_count"]
    assert_equal 111, @session.metadata["process_pid"]
  end

  test "merge_metadata! removes and merges in one statement, removal first" do
    @session.update!(metadata: { "interrupt_terminate_pid" => 999 })

    @session.merge_metadata!(
      { "process_pid" => 222, "runtime_started" => true },
      [ "interrupt_terminate_pid" ]
    )

    @session.reload
    assert_nil @session.metadata["interrupt_terminate_pid"]
    assert_equal 222, @session.metadata["process_pid"]
    assert_equal true, @session.metadata["runtime_started"]
  end

  test "merge_custom_metadata! keeps a key set after this object was loaded" do
    pr_url = "https://github.com/tadasant/zimmer/pull/1"
    stale = Session.find(@session.id)

    Session.find(@session.id).merge_custom_metadata!("github_pull_request_urls" => [ pr_url ])
    stale.merge_custom_metadata!("poller_last_polled_at" => { "github_pr" => "2026-01-01T00:00:00Z" })

    @session.reload
    assert_equal [ pr_url ], @session.custom_metadata["github_pull_request_urls"]
    assert_equal({ "github_pr" => "2026-01-01T00:00:00Z" }, @session.custom_metadata["poller_last_polled_at"])
  end

  test "merge leaves the in-memory object in sync with the row and not dirty" do
    @session.merge_metadata!("process_pid" => 333)

    assert_equal 333, @session.metadata["process_pid"], "in-memory value should reflect the write"
    refute @session.changed?, "the merged column must not be left dirty"
    assert_equal @session.metadata, Session.find(@session.id).metadata
  end

  test "merge does not clobber other unsaved attribute changes" do
    @session.title = "unsaved title"
    @session.merge_metadata!("process_pid" => 444)

    assert @session.title_changed?, "an unrelated dirty attribute must stay dirty"
    @session.save!
    assert_equal "unsaved title", @session.reload.title
    assert_equal 444, @session.metadata["process_pid"]
  end

  test "merge touches updated_at like update! does" do
    @session.update!(updated_at: 1.hour.ago)

    assert_changes -> { @session.reload.updated_at } do
      @session.merge_metadata!("process_pid" => 555)
    end
  end

  test "merge with nothing to do is a no-op that still returns the current value" do
    assert_no_changes -> { @session.reload.updated_at } do
      assert_equal({ "process_pid" => 111 }, @session.merge_metadata!)
    end
  end

  test "merge accepts symbol keys and stores them as strings" do
    @session.merge_metadata!(runtime_started: true)

    assert_equal true, @session.reload.metadata["runtime_started"]
  end

  test "merge starts from an empty object when the column is null" do
    @session.update_column(:metadata, nil)

    @session.merge_metadata!("process_pid" => 666)

    assert_equal({ "process_pid" => 666 }, @session.reload.metadata)
  end

  test "merge binds keys rather than interpolating them into SQL" do
    hostile = "a'); DROP TABLE sessions; --"
    @session.update!(metadata: { "process_pid" => 111, "doomed" => 1 })

    @session.merge_metadata!({ hostile => "kept" }, [ "doomed", "?" ])

    @session.reload
    assert Session.exists?(@session.id)
    assert_equal "kept", @session.metadata[hostile]
    assert_nil @session.metadata["doomed"]
    assert_equal 111, @session.metadata["process_pid"]
  end

  # A raw UPDATE fires no after_update_commit, so the concern re-dispatches the
  # broadcasts by hand. Missing one is invisible in a unit test and shows up as a card
  # that silently stops updating in someone's browser — GithubPrTrackingTest caught
  # exactly that for the index card. These pin all three.
  test "merging metadata re-broadcasts the session card on the index" do
    @session.expects(:broadcast_update_to_sessions_index).once
    @session.expects(:broadcast_metadata_change).never

    @session.merge_metadata!("process_pid" => 888)
  end

  test "merging a displayed metadata field also re-broadcasts the metadata partial" do
    @session.expects(:broadcast_update_to_sessions_index).once
    @session.expects(:broadcast_metadata_change).once

    @session.merge_metadata!("failure_reason" => "spawn_failed")
  end

  test "merging custom_metadata re-broadcasts the index card and the header actions" do
    @session.expects(:broadcast_update_to_sessions_index).once
    @session.expects(:broadcast_custom_metadata_change).with(mcp_status_changed: false).once

    @session.merge_custom_metadata!("github_pull_request_urls" => [ "https://github.com/o/r/pull/1" ])
  end

  test "merging mcp_servers_status flags the status change for the header broadcast" do
    @session.expects(:broadcast_update_to_sessions_index).once
    @session.expects(:broadcast_custom_metadata_change).with(mcp_status_changed: true).once

    @session.merge_custom_metadata!("mcp_servers_status" => { "a" => { "status" => "connected" } })
  end

  test "a merge that changes nothing broadcasts nothing" do
    @session.expects(:broadcast_update_to_sessions_index).never
    @session.expects(:broadcast_custom_metadata_change).never

    @session.merge_metadata!("process_pid" => 111)
  end

  test "merge rejects a column that is not a mergeable JSON column" do
    assert_raises(ArgumentError) { @session.send(:atomic_json_merge!, :prompt, { "a" => 1 }, []) }
  end

  test "merge raises when the row is gone" do
    id = @session.id
    ghost = Session.find(id)
    Session.where(id: id).delete_all

    assert_raises(ActiveRecord::RecordNotFound) { ghost.merge_metadata!("process_pid" => 777) }
  end
end
