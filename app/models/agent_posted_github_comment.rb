# frozen_string_literal: true

# A GitHub comment that one of Zimmer's own sessions posted.
#
# The poller's author check cannot see this: `gh` inside every session
# authenticates as the human (`tadasant`), so an agent's comment and a human's
# comment have the same `user.login`. What Zimmer has that GitHub doesn't is the
# transcript — it watched the tool call that posted the comment and read the
# comment URL out of that call's output. TranscriptHooks::GithubCommentAuthorshipHook
# writes those rows; Github::CommentEvaluator reads them.
#
# Rows are global rather than per-session, which is the point: the observed loop
# was cross-session (session A posts, session B is woken to "reply"), so the fact
# has to be visible to every session's poll, not just the poster's.
class AgentPostedGithubComment < ApplicationRecord
  # "pr" — an issue comment on the PR (`gh pr comment`).
  # "review" — an inline comment on a diff (`gh api .../pulls/N/comments`).
  # GitHub numbers the two independently, so an id is only unique within a type.
  COMMENT_TYPES = %w[pr review].freeze

  belongs_to :session, optional: true

  validates :comment_type, inclusion: { in: COMMENT_TYPES }
  validates :comment_id, presence: true, uniqueness: { scope: :comment_type }

  # Record a comment as agent-posted. Idempotent: the hook rescans the whole
  # transcript on every poll, so the same comment is offered many times, and two
  # pollers can offer it at once. A losing race returns the existing row rather
  # than raising — the fact is what matters, not who wrote it down.
  #
  # @return [AgentPostedGithubComment] the persisted row
  def self.record!(comment_type:, comment_id:, session: nil, comment_url: nil, pr_url: nil)
    create!(
      session: session,
      comment_type: comment_type,
      comment_id: comment_id,
      comment_url: comment_url,
      pr_url: pr_url
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    existing = find_by(comment_type: comment_type, comment_id: comment_id)
    raise unless existing

    existing
  end

  # The row for a comment, or nil when Zimmer never saw a session post it.
  #
  # @param comment_type [String] "pr" or "review"
  # @param comment_id [Integer, String] the GitHub comment id
  def self.posted_by_agent(comment_type:, comment_id:)
    return nil if comment_id.blank?

    find_by(comment_type: comment_type, comment_id: comment_id)
  end
end
