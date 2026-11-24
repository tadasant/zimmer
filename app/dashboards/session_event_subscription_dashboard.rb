# frozen_string_literal: true

require "administrate/base_dashboard"

# Who hears a session's events (SessionEventSubscription). `last_event_at` is when one was last
# delivered to that subscriber.
#
# Read-only by construction: FORM_ATTRIBUTES is empty and the route offers index and show only. A
# row is written when a session is spawned.
class SessionEventSubscriptionDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session_id: Field::Number,
    subscriber_type: Field::String,
    subscriber_id: Field::Number,
    event_names: Field::String.with_options(searchable: false),
    last_event_id: Field::String,
    last_event_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    session_id
    subscriber_type
    subscriber_id
    event_names
    last_event_id
    last_event_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session_id
    subscriber_type
    subscriber_id
    event_names
    last_event_id
    last_event_at
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(record)
    "session #{record.session_id} → #{record.subscriber_type} #{record.subscriber_id}"
  end
end
