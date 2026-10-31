# frozen_string_literal: true

# Probes the MCP servers that reachability-gated schedules wait for, once a minute, and records
# what it saw on each condition. ScheduleTriggerJob reads that record when a gated slot is due
# and never probes itself, so a hung host costs this job its timeouts and nothing else — the
# session wakes ScheduleTriggerJob delivers are not held behind it. See ScheduleReachabilityGate.
#
# Every gated condition on an enabled trigger is probed, due or not, so the dwell a slot waits
# out is the server's real uptime rather than time counted from the slot. Probes are cached per
# server, so ten conditions naming one laptop are one `tools/list` a minute.
class ScheduleReachabilityProbeJob < ApplicationJob
  queue_as :pollers

  # At most one pass unfinished at a time: a pass held up by unreachable hosts must not stack.
  include SingletonSweep

  def perform
    TriggerCondition.schedule
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .where("trigger_conditions.configuration ? 'require_reachable'")
      .find_each do |condition|
      next unless condition.reachability_gated?

      ScheduleReachabilityGate.observe!(condition)
    rescue => e
      Rails.logger.error "[ScheduleReachabilityProbeJob] Condition #{condition.id}: #{e.class}: #{e.message}"
      ErrorReporter.report_exception(e, context: { source: "ScheduleReachabilityProbeJob", condition_id: condition.id, trigger_id: condition.trigger_id })
    end
  end
end
