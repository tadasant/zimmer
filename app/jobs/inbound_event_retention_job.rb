# frozen_string_literal: true

# Deletes webhook dedup rows past their retention: WebhookDelivery after
# WebhookDelivery::RETENTION (7 days), TriggerEventClaim, TriggerShadowObservation and
# GithubPrShadowObservation after their RETENTION (30 days), and GithubPrSignal after
# GithubPrSignal::RETENTION (1 day). Without it the tables grow with every Slack message the bot can see, forever.
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
    observations = prune(TriggerShadowObservation, TriggerShadowObservation.expired(now))
    # Nothing logs these: a signal nobody has repeated for a day is simply no longer news.
    signals = prune(GithubPrSignal, GithubPrSignal.expired(now))
    pr_observations = prune(GithubPrShadowObservation, GithubPrShadowObservation.expired(now))

    if deliveries.positive? || claims.positive? || observations.positive?
      Rails.logger.info(
        "[InboundEventRetentionJob] deleted #{deliveries} webhook deliver#{deliveries == 1 ? 'y' : 'ies'} older than " \
        "#{WebhookDelivery::RETENTION.inspect} and #{claims} trigger event claim(s) older than #{TriggerEventClaim::RETENTION.inspect}" \
        "#{", and #{observations} shadow observation(s)" if observations.positive?}"
      )
    end

    { deliveries: deliveries, claims: claims, shadow_observations: observations, github_pr_signals: signals,
      github_pr_shadow_observations: pr_observations }
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
