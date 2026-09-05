require "test_helper"
require_relative "../support/mock_file_system_adapter"

# zimmer#576: the runtime names its transcript directory after the cwd it was
# spawned from, so a re-clone at a fresh path re-writes the whole conversation
# under a new slug. SessionClonePath is the decision that stops that.
class SessionClonePathTest < ActiveSupport::TestCase
  setup do
    @clones_base = Dir.mktmpdir("session_clone_path_test")
    @original_clones_dir = ENV["AGENT_CLONES_DIR"]
    ENV["AGENT_CLONES_DIR"] = @clones_base

    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    @previous_clone = File.join(@clones_base, "repo-main-1780000000-deadbeef")
    @file_system = MockFileSystemAdapter.new
  end

  teardown do
    ENV["AGENT_CLONES_DIR"] = @original_clones_dir
    FileUtils.rm_rf(@clones_base)
  end

  test "reuses the previous clone path when nothing is standing at it" do
    @session.update!(metadata: { "clone_path" => @previous_clone })

    assert_equal @previous_clone,
      SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "hands the path back verbatim so the transcript slug comes out identical" do
    @session.update!(metadata: { "clone_path" => @previous_clone })

    reused = SessionClonePath.for_recreate(@session, file_system: @file_system)
    source = ClaudeTranscriptSource.new

    assert_equal source.transcript_directory(working_directory: @previous_clone),
      source.transcript_directory(working_directory: reused),
      "a reused path must derive the same transcript directory as the original"
  end

  test "declines when the path still exists, because git clone refuses a non-empty destination" do
    @session.update!(metadata: { "clone_path" => @previous_clone })
    @file_system.mkdir_p(@previous_clone)

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines when a file (not a directory) is standing at the path" do
    @session.update!(metadata: { "clone_path" => @previous_clone })
    @file_system.write(@previous_clone, "a dangling something")

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines when the session has no previous clone path" do
    @session.update!(metadata: {})

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines a blank clone path" do
    @session.update!(metadata: { "clone_path" => "  " })

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines a path that is not a direct child of the clones base" do
    @session.update!(metadata: { "clone_path" => "/var/tmp/somewhere-else" })

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines a path nested below the clones base" do
    @session.update!(metadata: { "clone_path" => File.join(@clones_base, "repo-main-1-a", "subdir") })

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines the clones base itself" do
    @session.update!(metadata: { "clone_path" => @clones_base })

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines a relative path" do
    @session.update!(metadata: { "clone_path" => "clones/repo-main-1-a" })

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines a non-string clone path rather than raising" do
    @session.update!(metadata: { "clone_path" => 42 })

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "declines rather than raising when the session is nil" do
    assert_nil SessionClonePath.for_recreate(nil, file_system: @file_system)
  end

  test "declines rather than raising when the existence check blows up" do
    @session.update!(metadata: { "clone_path" => @previous_clone })

    exploding = Class.new(MockFileSystemAdapter) do
      def exists?(_path) = raise(Errno::EACCES, "nope")
    end.new

    assert_nil SessionClonePath.for_recreate(@session, file_system: exploding)
  end

  test "declines a dangling symlink standing at the path" do
    @session.update!(metadata: { "clone_path" => @previous_clone })
    dangling = MockFileSystemAdapter.new
    dangling.define_singleton_method(:symlink?) { |_path| true }

    assert_nil SessionClonePath.for_recreate(@session, file_system: dangling),
      "File.exist? answers false for a dangling symlink, but git clone still refuses the path"
  end

  # AtomicCloneRemoval's in-place fallback rm_rf's the live path and writes a
  # sibling marker first, precisely so this state is nameable while it runs.
  test "declines a path an in-place delete is still walking" do
    @session.update!(metadata: { "clone_path" => @previous_clone })
    File.write("#{@previous_clone}#{AtomicCloneRemoval::TOMBSTONE_MARKER}deadbeef", "")

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "reuses the path once the in-place delete marker is gone" do
    @session.update!(metadata: { "clone_path" => @previous_clone })
    marker = "#{@previous_clone}#{AtomicCloneRemoval::TOMBSTONE_MARKER}deadbeef"
    File.write(marker, "")
    File.delete(marker)

    assert_equal @previous_clone, SessionClonePath.for_recreate(@session, file_system: @file_system)
  end

  test "only for_recreate is a door" do
    assert_not SessionClonePath.respond_to?(:direct_child_of_clones_base?),
      "the fence is an implementation detail of the decision, not a second entry point"
    assert_not SessionClonePath.respond_to?(:in_place_delete_in_progress?)
  end

  test "follows AGENT_CLONES_DIR rather than a memoized base" do
    other_base = Dir.mktmpdir("session_clone_path_other_base")
    @session.update!(metadata: { "clone_path" => File.join(other_base, "repo-main-1-a") })

    assert_nil SessionClonePath.for_recreate(@session, file_system: @file_system),
      "a path under a different base is not a clone of this deployment"

    ENV["AGENT_CLONES_DIR"] = other_base
    assert_equal File.join(other_base, "repo-main-1-a"),
      SessionClonePath.for_recreate(@session, file_system: @file_system)
  ensure
    FileUtils.rm_rf(other_base)
  end
end
