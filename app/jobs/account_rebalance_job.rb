# frozen_string_literal: true

# The proactive half of Claude Code account rotation: every few minutes, ask
# AccountRebalanceService whether an idle pool should move to a better account,
# and move it if so. Off the request path entirely — no session start or turn
# waits on this — and a no-op whenever any turn is in flight or the pool has
# been active within the prompt-cache TTL.
class AccountRebalanceJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  def perform
    result = AccountRebalanceService.new.rebalance!
    Rails.logger.debug("[AccountRebalanceJob] #{result.except(:event).inspect}") unless result[:rebalanced]
    result
  rescue StandardError => e
    Rails.logger.warn("[AccountRebalanceJob] Rebalance failed: #{e.class}: #{e.message}")
    nil
  end
end
