# frozen_string_literal: true

# One inbound webhook delivery Zimmer accepted, keyed on the provider's own delivery id.
#
# The provider decides what a "delivery" is and names it: Slack's `event_id` stays the same
# across every retry of one event, and Slack retries on a timeout or any non-2xx. Recording the
# id under a unique index is what makes a retry a no-op — see .record_first!.
#
# A row is written for every accepted delivery, including the ones no trigger matches, so the
# table also answers "is Slack delivering at all" without a shell: the newest row is the last
# delivery that verified.
class WebhookDelivery < ApplicationRecord
  SOURCES = %w[slack github].freeze

  # Slack retries a delivery three times, the last about five minutes after the first, so a
  # day would cover redelivery on its own; GitHub does not retry, and a redelivery is someone
  # pressing "Redeliver". The rest of the week is for reading back what arrived when a trigger
  # did or did not fire.
  RETENTION = 7.days

  validates :source, inclusion: { in: SOURCES }
  validates :delivery_id, presence: true

  scope :expired, ->(now = Time.current) { where(created_at: ...(now - RETENTION)) }

  # Record a delivery unless it has been recorded already.
  #
  # Returns true the first time a (source, delivery_id) pair is seen and false for every
  # redelivery. An `INSERT ... ON CONFLICT DO NOTHING`, so two copies racing each other are
  # decided by the unique index rather than by a read that both could pass.
  def self.record_first!(source:, delivery_id:, event_type: nil, retry_num: nil, now: Time.current)
    result = insert_all(
      [ { source: source, delivery_id: delivery_id, event_type: event_type, retry_num: retry_num, created_at: now } ],
      unique_by: %i[source delivery_id],
      returning: %i[id]
    )
    result.rows.any?
  end
end
