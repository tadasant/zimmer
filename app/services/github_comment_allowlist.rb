# The GitHub accounts whose PR comments Zimmer trusts.
#
# This is the trust boundary for the whole PR-comment path, and it has to be one
# list rather than two. `GithubCommentPollerJob` consults it to decide whether a
# comment may wake a session at all; `GithubCommentPromptBuilder` consults it again
# to decide whether a *neighbouring* comment's body may be quoted into that
# session's prompt. When those two answers came from separate literals, an outsider
# could not trigger a session but could still place chosen text in one -- by
# commenting on any open PR that a trusted human later replied to.
#
# GitHub usernames are case-insensitive; the list is lowercase and callers go
# through .include?, which downcases.
module GithubCommentAllowlist
  USERS = %w[tadasant macoughl].freeze

  # @param author [String, nil] a GitHub login
  def self.include?(author)
    USERS.include?(author.to_s.downcase)
  end
end
