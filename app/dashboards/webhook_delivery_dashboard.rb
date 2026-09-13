require "administrate/base_dashboard"

# Every inbound webhook delivery that verified and was accepted, keyed on the provider's own
# delivery id (Slack's `event_id`). The no-shell answer to "is Slack delivering at all": the
# newest row is the last delivery that passed signature verification.
#
# Read-only by construction: FORM_ATTRIBUTES is empty and the route offers index and show only.
# A row records what arrived, and a hand-authored one would claim a delivery that never happened
# — and, since the unique index is the redelivery guard, would make a real one with that id be
# ignored.
class WebhookDeliveryDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    source: Field::String,
    delivery_id: Field::String,
    event_type: Field::String,
    retry_num: Field::Number,
    created_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    source
    delivery_id
    event_type
    retry_num
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    source
    delivery_id
    event_type
    retry_num
    created_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(delivery)
    "#{delivery.source} #{delivery.delivery_id}"
  end
end
