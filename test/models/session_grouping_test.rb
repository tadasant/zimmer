require "test_helper"

class SessionGroupingTest < ActiveSupport::TestCase
  test "parent_session association returns parent" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent")
    child = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child", parent_session_id: parent.id)

    assert_equal parent, child.parent_session
  end

  test "child_sessions association returns children" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent")
    child1 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child 1", parent_session_id: parent.id)
    child2 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child 2", parent_session_id: parent.id)

    assert_includes parent.child_sessions, child1
    assert_includes parent.child_sessions, child2
    assert_equal 2, parent.child_sessions.size
  end

  test "root_sessions scope excludes child sessions" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent")
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child", parent_session_id: parent.id)
    standalone = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Standalone")

    roots = Session.root_sessions
    assert_includes roots, parent
    assert_includes roots, standalone
    # Child should not be in roots
    refute roots.any? { |s| s.prompt == "Child" }
  end

  test "children_of scope returns children for a parent" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent")
    child = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child", parent_session_id: parent.id)
    other = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Other")

    children = Session.children_of(parent.id)
    assert_includes children, child
    refute_includes children, other
  end

  test "parent_session is optional" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "No parent")
    assert_nil session.parent_session
    assert session.valid?
  end

  # Tests for direct parent_session_id column usage

  test "parent_session_id set directly on create groups sessions" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Router session")
    child1 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child 1", parent_session_id: parent.id)
    child2 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child 2", parent_session_id: parent.id)

    assert_includes parent.child_sessions.reload, child1
    assert_includes parent.child_sessions.reload, child2

    roots = Session.root_sessions
    assert_includes roots, parent
    refute_includes roots, child1
    refute_includes roots, child2
  end

  test "parent_session_id accepted via API params on session create" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Router session")
    child = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Spawned session", parent_session_id: parent.id)

    assert_equal parent.id, child.parent_session_id
    assert_equal parent, child.parent_session
  end

  test "custom_metadata does not affect parent_session_id column" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Session", custom_metadata: { "parent_session_id" => 99999 })
    assert_nil session.parent_session_id, "custom_metadata.parent_session_id should not sync to the column"
  end

  # The sessions-index broadcast path for parent/child sessions (a child renders its
  # own individual card to "sessions_index_individual") is covered by
  # SessionTest#"child session update broadcasts individual card to
  # sessions_index_individual".
end
