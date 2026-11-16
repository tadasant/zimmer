# frozen_string_literal: true

# One GitHub event one delivery path saw for one trigger condition while GitHub ingest is in
# `webhook_shadow` (Webhooks::Source).
#
#   webhook  GithubEventJob matched a delivery against the condition and WOULD have fired it.
#            Nothing fired and nothing was claimed; `delivery_id` is the `X-GitHub-Delivery` id.
#   poll     GithubTriggerPollerJob fired the condition for the event, as it does on `poll`.
#
# The event key is the TriggerEventClaim key the same fire would have claimed, so a row from each
# path for one condition and key is one event both paths saw. Webhooks::GithubShadowComparison
# pairs them. Rows are recorded only in `webhook_shadow`: `poll` writes nothing new, and
# `webhook_with_poll_fallback` already says which path won through TriggerEventClaim.
class TriggerShadowObservation < ApplicationRecord
  PATHS = %w[webhook poll].freeze

  # As long as a claim lives, so a comparison can reach as far back as compare_trigger_fires.
  RETENTION = TriggerEventClaim::RETENTION

  belongs_to :trigger_condition

  validates :event_key, presence: true
  validates :path, inclusion: { in: PATHS }

  scope :expired, ->(now = Time.current) { where(created_at: ...(now - RETENTION)) }

  # Records one observation. A webhook row is unique per delivery, so a retried job is a no-op.
  def self.record!(condition, event_key, path:, delivery_id: nil, now: Time.current)
    insert_all(
      [ { trigger_condition_id: condition.id, event_key: event_key, path: path, delivery_id: delivery_id, created_at: now } ],
      unique_by: :index_trigger_shadow_observations_on_delivery
    )
  end
end
