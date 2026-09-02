# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The last guard before a clone's bytes go. Everything here is about the gap
# between a sweep's ownership snapshot and the moment it actually deletes
# something — see zimmer#808.
class CloneReaperTest < ActiveSupport::TestCase
  setup do
    @clones_base = Dir.mktmpdir("clone-reaper-test")
    @clone_path = File.join(@clones_base, "zimmer-main-1788364605-45c2382a")
    FileUtils.mkdir_p(File.join(@clone_path, ".git"))
  end

  teardown do
    FileUtils.rm_rf(@clones_base)
  end

  test "deletes a clone no live session owns" do
    assert_equal :removed, CloneReaper.reap(@clone_path, reason: "test")
    assert_not File.directory?(@clone_path)
  end

  test "reports an absent path rather than deleting" do
    assert_equal :absent, CloneReaper.reap(File.join(@clones_base, "gone"), reason: "test")
  end

  test "treats a blank path as absent" do
    assert_equal :absent, CloneReaper.reap(nil, reason: "test")
    assert_equal :absent, CloneReaper.reap("", reason: "test")
  end

  test "deletes a clone owned by a terminal session" do
    sessions(:archived).update!(metadata: { "clone_path" => @clone_path })

    assert_equal :removed, CloneReaper.reap(@clone_path, reason: "test")
    assert_not File.directory?(@clone_path)
  end

  Session::NON_REAPABLE_STATUSES.each do |status|
    test "refuses to delete a clone owned by a #{status} session" do
      session = sessions(:archived)
      session.update_columns(status: Session.statuses[status], metadata: { "clone_path" => @clone_path })

      assert_equal :refused, CloneReaper.reap(@clone_path, reason: "test")
      assert File.directory?(@clone_path), "the clone of a #{status} session must survive"
      assert File.directory?(File.join(@clone_path, ".git"))
      assert_not session.reload.logs.where(level: "warning").where("content LIKE ?", "%about to delete%").empty?,
                 "a refusal must leave a durable, attributable record on the session"
    end
  end

  test "refuses when the owning session woke up after the caller's snapshot" do
    # Exactly the zimmer#808 shape: the sweep decided this clone was reapable
    # while its session was archived, and the session was unarchived before the
    # sweep got to it.
    session = sessions(:archived)
    session.update!(metadata: { "clone_path" => @clone_path })
    snapshot = Session.live_clone_paths
    assert_not_includes snapshot, File.expand_path(@clone_path)

    session.update_columns(status: Session.statuses[:running])

    assert_equal :refused, CloneReaper.reap(@clone_path, reason: "test")
    assert File.directory?(@clone_path)
  end

  test "matches an owner whose stored clone_path cannot be reconciled by expand_path" do
    # A relocated or symlinked clones base: same clone, different absolute path.
    # The basename is globally unique, so it is the handle that survives.
    sessions(:running).update!(
      metadata: { "clone_path" => File.join("/somewhere/else", File.basename(@clone_path)) }
    )

    assert_equal :refused, CloneReaper.reap(@clone_path, reason: "test")
    assert File.directory?(@clone_path)
  end

  test "fails closed when ownership cannot be read" do
    Session.stubs(:unscoped).raises(ActiveRecord::ConnectionNotEstablished, "no database")

    assert_equal :refused, CloneReaper.reap(@clone_path, reason: "test")
    assert File.directory?(@clone_path), "an unanswerable question is answered 'live'"
  end

  test "removal is atomic — the clone is renamed aside, never stripped in place" do
    AtomicCloneRemoval.expects(:remove).with(@clone_path, has_key(:file_system)).returns(true)

    assert_equal :removed, CloneReaper.reap(@clone_path, reason: "test")
  end

  test "a refusal survives a session log write that fails" do
    sessions(:running).update!(metadata: { "clone_path" => @clone_path })
    Session.any_instance.stubs(:logs).raises(ActiveRecord::StatementInvalid, "boom")

    assert_equal :refused, CloneReaper.reap(@clone_path, reason: "test")
    assert File.directory?(@clone_path)
  end
end
