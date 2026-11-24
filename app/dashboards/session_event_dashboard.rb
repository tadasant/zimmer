# frozen_string_literal: true

require "administrate/base_dashboard"

# What Zimmer's own MCP server publishes as MCP Events (SessionEvents), one row per occurrence.
#
# Read-only by construction: FORM_ATTRIBUTES is empty and the route offers index and show only. A
# hand-authored row would be an event that never happened, served to every poller.
class SessionEventDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    event_id: Field::String,
    name: Field::String,
    session_id: Field::Number,
    parent_session_id: Field::Number,
    agent_root: Field::String,
    data: Field::String.with_options(searchable: false),
    occurred_at: Field::DateTime,
    txid: Field::Number,
    created_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    event_id
    name
    session_id
    agent_root
    data
    occurred_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    event_id
    name
    session_id
    parent_session_id
    agent_root
    data
    occurred_at
    txid
    created_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(record)
    "#{record.name} #{record.event_id}"
  end
end
