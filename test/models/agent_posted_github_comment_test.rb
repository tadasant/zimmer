require "test_helper"

class AgentPostedGithubCommentTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
  end

  test "records a comment and finds it back" do
    AgentPostedGithubComment.record!(
      session: @session,
      comment_type: "pr",
      comment_id: 5145406778,
      comment_url: "https://github.com/tadasant/tadasant-internal/pull/281#issuecomment-5145406778",
      pr_url: "https://github.com/tadasant/tadasant-internal/pull/281"
    )

    found = AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 5145406778)
    assert_not_nil found
    assert_equal @session.id, found.session_id
  end

  test "record! is idempotent for the same comment" do
    first = AgentPostedGithubComment.record!(session: @session, comment_type: "pr", comment_id: 42)

    assert_no_difference "AgentPostedGithubComment.count" do
      second = AgentPostedGithubComment.record!(session: @session, comment_type: "pr", comment_id: 42)
      assert_equal first.id, second.id
    end
  end

  test "record! returns the existing row when the unique index is what rejects the insert" do
    existing = AgentPostedGithubComment.record!(session: @session, comment_type: "pr", comment_id: 99)

    # The losing side of a genuine race between two pollers: the uniqueness
    # validation's SELECT ran before the other insert committed, so validation
    # passes and only the index catches it.
    AgentPostedGithubComment.any_instance.stubs(:valid?).returns(true)

    result = nil
    assert_no_difference "AgentPostedGithubComment.count" do
      result = AgentPostedGithubComment.record!(session: @session, comment_type: "pr", comment_id: 99)
    end
    assert_equal existing.id, result.id
  end

  test "pr and review ids live in separate namespaces" do
    AgentPostedGithubComment.record!(session: @session, comment_type: "pr", comment_id: 7)
    AgentPostedGithubComment.record!(session: @session, comment_type: "review", comment_id: 7)

    assert_equal 2, AgentPostedGithubComment.where(comment_id: 7).count
    assert_not_nil AgentPostedGithubComment.posted_by_agent(comment_type: "review", comment_id: 7)
  end

  test "posted_by_agent returns nil for an unknown comment and for a blank id" do
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: 123456)
    assert_nil AgentPostedGithubComment.posted_by_agent(comment_type: "pr", comment_id: nil)
  end

  test "rejects an unknown comment type" do
    record = AgentPostedGithubComment.new(comment_type: "discussion", comment_id: 1)
    assert_not record.valid?
    assert_includes record.errors[:comment_type], "is not included in the list"
  end

  test "outlives the session that posted it" do
    record = AgentPostedGithubComment.record!(session: @session, comment_type: "pr", comment_id: 555)

    @session.destroy!

    assert_not_nil AgentPostedGithubComment.find_by(id: record.id), "the comment record must survive its session"
    assert_nil record.reload.session_id
  end
end
