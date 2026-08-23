# The GitHub accounts whose PR comments Zimmer trusts.
#
# This is the trust boundary for the whole PR-comment path, and it is one list
# rather than two. `GithubCommentPollerJob` consults it to decide whether a comment
# may wake a session at all; `GithubCommentPromptBuilder` consults it again to
# decide whether a *neighbouring* comment's body may be quoted into that session's
# prompt. Two separate literals would let those answers drift: an outsider who
# cannot trigger a session could still place chosen text in one, by commenting on
# any open PR that a trusted human later replies to.
#
# `trusted?` rather than `include?`: a module already answers `include?`, about
# ancestry, and a caller reaching that one by accident would get a confident wrong
# answer about who Zimmer trusts.
#
# GitHub usernames are case-insensitive, so the list is lowercase and `trusted?`
# downcases. A blank or missing author fails closed.
module GithubCommentAllowlist
  USERS = %w[tadasant macoughl].freeze

  # @param author [String, nil] a GitHub login
  def self.trusted?(author)
    USERS.include?(author.to_s.downcase)
  end
end
