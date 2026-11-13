require "administrate/base_dashboard"

# The MCP Events webhook subscriptions McpEventSubscriptionsJob holds on catalog servers, one per
# `mcp_event` condition whose event type offers webhook delivery. The no-shell answer to "is push
# carrying this condition, and if not, why": state, the server's grant, the last signed request,
# and the last error, all as the job and the receiver recorded them.
#
# Read-only by construction: FORM_ATTRIBUTES is empty and the route offers index and show only.
# The job owns every row. A hand-edited callback URL or state would describe a subscription the
# server does not hold, and deleting a row would orphan the server's subscription until its grant
# ran out.
class McpEventWebhookSubscriptionDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    trigger_condition: Field::BelongsTo,
    server: Field::String,
    event_name: Field::String,
    arguments: Field::Text,
    state: Field::String,
    callback_url: Field::String,
    remote_id: Field::String,
    cursor: Field::Text,
    subscribed_at: Field::DateTime,
    refresh_before: Field::DateTime,
    verified_at: Field::DateTime,
    last_delivery_at: Field::DateTime,
    delivery_status: Field::Text,
    last_error: Field::String,
    failures: Field::Number,
    next_attempt_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  DELIBERATELY_OMITTED = [
    # The subscription's encrypted signing secret. Useless to a reader, and the panel is no place
    # for even ciphertext of a credential.
    :secret_ciphertext,
    # The URL path secret's other half: anyone holding a token can aim requests at a real
    # subscription. callback_url carries it already for an operator who needs it.
    :token
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    trigger_condition
    server
    event_name
    state
    refresh_before
    verified_at
    last_error
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    trigger_condition
    server
    event_name
    arguments
    state
    callback_url
    remote_id
    cursor
    subscribed_at
    refresh_before
    verified_at
    last_delivery_at
    delivery_status
    last_error
    failures
    next_attempt_at
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(subscription)
    "#{subscription.server} #{subscription.event_name} (#{subscription.state})"
  end
end
