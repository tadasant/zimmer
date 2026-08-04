# frozen_string_literal: true

# Posts a QueueRecoveryMode alert to Slack off the web request path.
#
# `AlertService.raise_alert` posts synchronously, and `SlackService` is allowed 5s
# connect + 10s read with three backing-off retries. That is fine on a worker
# thread. It is not fine on the web request that happened to be the one to notice
# the TTL had elapsed — `ApplicationController#reconcile_queue_recovery_mode` runs
# on an ordinary page load, and a user should not wait out a Slack outage for it.
#
# `default` is the right queue precisely because `QueueRecoveryMode#exit!` unpauses
# before it alerts: by the time this is enqueued, `default` is running again.
class QueueRecoveryModeAlertJob < ApplicationJob
  queue_as :default

  def perform(title, details, dedup_key)
    AlertService.raise_alert(
      title,
      details: details,
      source: QueueRecoveryMode.name,
      dedup_key: dedup_key
    )
  end
end
