# frozen_string_literal: true

# Records the GitHub comments Zimmer's own sessions posted, so the comment poller
# can tell them apart from the human's.
#
# Every session's `gh` authenticates as `tadasant`, so a comment an agent posts is
# indistinguishable *by author* from one the human wrote. The poller therefore
# handed agent-written comments back to sessions as "GitHub Comment Response
# Required" — including to a different session than the one that posted, which is
# a loop no single session can break by recognizing its own text.
#
# GitHub cannot answer "who really wrote this", but Zimmer can: it sees the tool
# call that posted the comment and the comment URL that call returned. This table
# is where that knowledge lands. It is global on purpose — the row is keyed by
# comment, not by session, so any session's poller consults the same fact.
#
# session_id is nullable with ON DELETE SET NULL: the row must outlive the session
# that posted it, because the comment does.
class CreateAgentPostedGithubComments < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_posted_github_comments do |t|
      t.references :session, foreign_key: { on_delete: :nullify }, null: true

      # "pr" (issue comment on the PR) or "review" (inline comment on a diff).
      # GitHub numbers these in two separate id spaces, so the pair is the key.
      t.string :comment_type, null: false
      t.bigint :comment_id, null: false

      t.string :comment_url
      t.string :pr_url

      t.timestamps
    end

    add_index :agent_posted_github_comments,
              [ :comment_type, :comment_id ],
              unique: true,
              name: "index_agent_posted_github_comments_on_type_and_comment_id"
  end
end
