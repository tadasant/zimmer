require "administrate/base_dashboard"

class MergeAttestationDashboard < Administrate::BaseDashboard
  # Every signed human merge approval this Zimmer issued to another deployment
  # or received from one (MergeAttestations).
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    direction: Field::String,
    outcome: Field::String,
    outcome_detail: Field::Text,
    pr_url: Field::String,
    repo: Field::String,
    pr_number: Field::Number,
    head_sha: Field::String,
    issuer: Field::String,
    audience: Field::String,
    key_id: Field::String,
    jti: Field::String,
    approver: Field::String,
    approver_name: Field::String,
    channel: Field::String,
    surface: Field::String,
    read_back: Field::Text,
    answer: Field::Text,
    approved_at: Field::DateTime,
    issued_at: Field::DateTime,
    expires_at: Field::DateTime,
    session: Field::BelongsTo,
    human_message: Field::BelongsTo,
    remote_server: Field::String,
    remote_session_url: Field::String,
    claims: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id direction outcome pr_url approver issued_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id direction outcome outcome_detail pr_url repo pr_number head_sha issuer audience key_id jti approver
    approver_name channel surface read_back answer approved_at issued_at expires_at session human_message
    remote_server remote_session_url claims created_at updated_at
  ].freeze

  # Deliberately empty, and the route offers index and show only. A
  # MergeAttestation's approval columns are immutable and the row cannot be
  # destroyed: it is the record that a person approved a merge, and an edit
  # here would make it say something they did not.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {
    issued: ->(resources) { resources.issued },
    received: ->(resources) { resources.received }
  }.freeze
end
