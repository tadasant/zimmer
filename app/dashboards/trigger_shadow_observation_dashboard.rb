require "administrate/base_dashboard"

# One GitHub event one delivery path saw for one trigger condition while GitHub ingest is in
# `webhook_shadow`: `webhook` is a delivery that would have fired the condition, `poll` a fire the
# poller made. Webhooks::GithubShadowComparison pairs them; this page lists them row by row.
#
# Read-only by construction: FORM_ATTRIBUTES is empty and the route offers index and show only.
# The rows are the comparison's evidence, so an edited one would change what it reports.
class TriggerShadowObservationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    trigger_condition: Field::BelongsTo,
    event_key: Field::String,
    path: Field::String,
    delivery_id: Field::String,
    created_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    trigger_condition
    event_key
    path
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    trigger_condition
    event_key
    path
    delivery_id
    created_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(observation)
    "#{observation.path} #{observation.event_key}"
  end
end
