# frozen_string_literal: true

# Deletes webhook dedup rows past their retention: WebhookDelivery after
# WebhookDelivery::RETENTION (7 days) and TriggerEventClaim after TriggerEventClaim::RETENTION
# (30 days). Without it both tables grow with every Slack message the bot can see, forever.
#
# Idempotent — a run with nothing expired deletes nothing — and batched, so a backlog after a
# long gap drains a slice at a time instead of in one statement.
#
# On `default`, not `maintenance`: it is a daily run of indexed deletes that returns its thread in
# well under a second, not the minutes-long work that lane exists to keep off `default`.
class InboundEventRetentionJob < ApplicationJob
  include SingletonSweep

  queue_as :default

  BATCH_SIZE = 5_000

  def perform(now: Time.current)
    deliveries = prune(WebhookDelivery, WebhookDelivery.expired(now))
    claims = prune(TriggerEventClaim, TriggerEventClaim.expired(now))

    if deliveries.positive? || claims.positive?
      Rails.logger.info(
        "[InboundEventRetentionJob] deleted #{deliveries} webhook deliver#{deliveries == 1 ? 'y' : 'ies'} older than " \
        "#{WebhookDelivery::RETENTION.inspect} and #{claims} trigger event claim(s) older than #{TriggerEventClaim::RETENTION.inspect}"
      )
    end

    { deliveries: deliveries, claims: claims }
  end

  private

  def prune(model, scope)
    total = 0

    loop do
      ids = scope.limit(BATCH_SIZE).pluck(:id)
      break if ids.empty?

      total += model.where(id: ids).delete_all
      break if ids.size < BATCH_SIZE
    end

    total
  end
end
