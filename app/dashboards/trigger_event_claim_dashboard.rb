require "administrate/base_dashboard"

# A trigger condition's claim on one external event: which path (`webhook` or `poll`) fired a
# Slack message for that condition first, and the session it produced. While both paths run, a
# `poll` claim on a message Slack should have delivered is a delivery the webhook missed, which is
# what this page is for.
#
# Read-only by construction: FORM_ATTRIBUTES is empty and the route offers index and show only.
# The unique index on these rows is what keeps the two paths from firing one message twice, so an
# edited or deleted claim would let the other path fire it again.
class TriggerEventClaimDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    trigger_condition: Field::BelongsTo,
    event_key: Field::String,
    claimed_via: Field::String,
    session: Field::BelongsTo,
    group_key: Field::String,
    anchor_ts: Field::String.with_options(searchable: false),
    created_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    trigger_condition
    event_key
    claimed_via
    session
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    trigger_condition
    event_key
    claimed_via
    session
    group_key
    anchor_ts
    created_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(claim)
    "#{claim.claimed_via} #{claim.event_key}"
  end
end
