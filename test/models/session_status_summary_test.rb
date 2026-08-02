# frozen_string_literal: true

require "test_helper"

# The staleness arithmetic behind the Status panel's "N messages since summary
# generated" line and behind the refusal to regenerate a current summary.
class SessionStatusSummaryTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      prompt: "work",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  def summary(**attrs)
    SessionStatusSummary.create!({ session: @session, state: "ready" }.merge(attrs))
  end

  test "messages_since is the difference between the live count and the count at generation" do
    record = summary(summary: "All good.", transcript_line_count: 40)

    assert_equal 0, record.messages_since(40)
    assert_equal 7, record.messages_since(47)
  end

  test "messages_since never goes negative when a transcript shrinks" do
    record = summary(summary: "All good.", transcript_line_count: 40)

    assert_equal 0, record.messages_since(12)
  end

  test "a summary of an unchanged session is not stale" do
    record = summary(summary: "All good.", transcript_line_count: 40)

    assert_not record.stale?(40)
  end

  test "one new transcript line makes a summary stale" do
    record = summary(summary: "All good.", transcript_line_count: 40)

    assert record.stale?(41)
  end

  test "a record with no summary text is always stale" do
    record = summary(summary: nil, state: "idle", transcript_line_count: 40)

    assert record.stale?(40)
  end

  test "a generation started just now is pending" do
    record = summary(state: "pending", requested_at: 1.minute.ago)

    assert record.pending?
    assert_not record.abandoned?
  end

  test "a generation that outlived the timeout is abandoned, not pending" do
    record = summary(state: "pending", requested_at: (SessionStatusSummary::PENDING_TIMEOUT + 1.minute).ago)

    assert_not record.pending?
    assert record.abandoned?
  end

  # The generating fork writes absolute URLs (it cannot know where its answer
  # renders), but a link to this session's own transcript is a fragment on the
  # page the reader is already on.
  test "a link to this session's own transcript collapses to a bare fragment" do
    record = summary(summary: "CI went red — [see here](https://zimmer.example.com/sessions/#{@session.id}#message-6).")

    assert_equal "CI went red — [see here](#message-6).", record.summary_markdown
  end

  test "the host is not matched, so a summary written under a stale base URL still collapses" do
    record = summary(summary: "[here](http://localhost:3000/sessions/#{@session.id}#message-12)")

    assert_equal "[here](#message-12)", record.summary_markdown
  end

  test "a link to a different session is left absolute" do
    other = @session.id + 1
    text = "[that session](https://zimmer.example.com/sessions/#{other}#message-6)"

    assert_equal text, summary(summary: text).summary_markdown
  end

  test "an external link is left alone" do
    text = "[PR #301](https://github.com/tadasant/zimmer/pull/301)"

    assert_equal text, summary(summary: text).summary_markdown
  end

  test "state must be one of the known states" do
    record = SessionStatusSummary.new(session: @session, state: "whatever")

    assert_not record.valid?
    assert_includes record.errors[:state], "is not included in the list"
  end
end
