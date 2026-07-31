require "administrate/base_dashboard"

class AgentPostedGithubCommentDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    comment_type: Field::String,
    comment_id: Field::Number,
    comment_url: Field::String,
    pr_url: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    session
    comment_type
    comment_id
    pr_url
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    comment_type
    comment_id
    comment_url
    pr_url
    created_at
    updated_at
  ].freeze

  # Read-only: rows are written by TranscriptHooks::GithubCommentAuthorshipHook from
  # what a session actually did. Hand-editing one would assert an authorship Zimmer
  # never observed.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
