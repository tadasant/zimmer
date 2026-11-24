# frozen_string_literal: true

require "administrate/base_dashboard"

# What came back to Live Mode from work it started, and whether it has been said
# (LiveConversations::BackgroundResults). Read-only: that service owns every row.
class LiveBackgroundResultDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    live_conversation: Field::BelongsTo,
    root_session_id: Field::Number,
    session_id: Field::Number,
    event_id: Field::String,
    kind: Field::String,
    message: Field::Text,
    occurred_at: Field::DateTime,
    offered_at: Field::DateTime,
    offered_claim: Field::String,
    offered_conversation_id: Field::Number,
    offered_turn_id: Field::Number,
    delivered_at: Field::DateTime,
    delivered_after_turn_id: Field::Number,
    raised_at: Field::DateTime,
    dropped_at: Field::DateTime,
    drop_reason: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id live_conversation session_id kind created_at offered_at raised_at drop_reason].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    live_conversation
    root_session_id
    session_id
    event_id
    kind
    message
    occurred_at
    offered_at
    offered_claim
    offered_conversation_id
    offered_turn_id
    delivered_at
    delivered_after_turn_id
    raised_at
    dropped_at
    drop_reason
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
