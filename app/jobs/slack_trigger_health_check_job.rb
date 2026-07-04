# frozen_string_literal: true

# Proactively detects Slack trigger feeds that have silently stopped firing.
#
# The Slack poller is a polling loop: each new_message condition records the
# timestamp of the newest message it has processed (last_message_ts) and only
# advances it when it sees something newer. If a feed silently stops being
# delivered or processed — a channel that drops out of event delivery, a thread
# that's misconfigured so its replies are never seen, a token/permission change
# that quietly breaks one channel — the poller simply finds nothing new and
# stays quiet. Nobody notices until the downstream automation that depended on
# the trigger is conspicuously absent (which is exactly how the #data-updates
# anomaly-review net went dark for days; see issue #4335).
#
# This job closes that gap. Once an hour it asks Slack, for each enabled
# new_message condition, "what is the newest message in the source you monitor?"
# and compares that to what the poller has actually processed. If Slack has a
# message materially newer than the condition's last_message_ts — old enough
# that the once-a-minute poller should long since have caught it — the feed is
# stalled and we raise an alert so a human can investigate before days pass.
class SlackTriggerHealthCheckJob < ApplicationJob
  queue_as :default

  # How far behind the newest available message a condition may fall before we
  # consider its feed stalled. Generous enough to never flag the normal
  # sub-minute gap between a message arriving and the next poll tick (or a brief
  # poller backlog), but tight enough to catch a feed that has genuinely been
  # dead for hours.
  STALE_THRESHOLD_SECONDS = 3 * 60 * 60 # 3 hours

  # How many recent messages to scan when finding the newest top-level message,
  # so we can skip over thread replies/broadcasts the poller intentionally
  # ignores and still find a real top-level message to compare against.
  HISTORY_SCAN_LIMIT = 20

  def perform
    return unless SlackService.configured?

    AlertBatcher.with_batch do
      TriggerCondition.slack
        .joins(:trigger)
        .where(triggers: { status: "enabled" })
        .includes(:trigger)
        .find_each do |condition|
        check_condition(condition)
      rescue => e
        # An API hiccup checking one condition shouldn't abort the sweep or
        # masquerade as a stalled feed. Log at INFO — this self-resolves on the
        # next hourly run — and move on.
        Rails.logger.info "[SlackTriggerHealthCheckJob] Could not check condition #{condition.id}: #{e.message}"
      end
    end
  end

  private

  def check_condition(condition)
    # bot_mention conditions fan out across DMs and (optionally) every member
    # channel, each with its own per-source timestamp. There is no single
    # "newest message" to compare against, so staleness here isn't meaningful.
    return if condition.event_type == "bot_mention"

    channel_id = condition.channel_id
    return if channel_id.blank?

    last_processed = condition.last_message_ts
    # No baseline established yet (condition never polled, or thread has no
    # replies): there is nothing to fall behind on.
    return if last_processed.blank?

    latest_ts = latest_source_ts(condition, channel_id, last_processed)
    return if latest_ts.blank?

    # Slack timestamps are fixed-width "seconds.micros" strings, so lexical and
    # numeric ordering agree. Caught up (or ahead) → healthy.
    return if latest_ts <= last_processed

    lag_seconds = Time.now.to_f - latest_ts.to_f
    return if lag_seconds < STALE_THRESHOLD_SECONDS

    source = condition.thread_scoped? ? "thread #{condition.thread_ts}" : "##{condition.channel_name || channel_id}"
    AlertService.raise_alert(
      "Slack trigger feed stalled",
      details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) " \
               "monitoring #{source} has fallen behind. Slack's newest message (ts #{latest_ts}, " \
               "~#{(lag_seconds / 3600.0).round(1)}h old) is newer than the last one the poller processed " \
               "(ts #{last_processed}). The feed may have silently stopped being delivered or processed — " \
               "investigate before dependent automation goes dark.",
      source: "SlackTriggerHealthCheckJob",
      dedup_key: "slack_trigger_stalled_#{condition.id}"
    )
  end

  # The timestamp of the newest message the poller WOULD process for this
  # condition, or nil if the source currently has none.
  #
  # For staleness we only need to know whether anything newer than what the
  # poller already processed exists, so the thread scan is bounded by
  # last_processed rather than walking the entire (potentially years-long)
  # digest thread on every hourly run.
  def latest_source_ts(condition, channel_id, last_processed)
    if condition.thread_scoped?
      # Newest reply at or after the last processed one (get_thread_replies
      # excludes the parent; oldest is inclusive). If the only reply returned is
      # the already-processed baseline, max == last_processed and the caller
      # reads that as caught-up.
      SlackService.get_thread_replies(channel_id, condition.thread_ts, oldest: last_processed).map(&:ts).max
    else
      # Newest TOP-LEVEL message, mirroring fetch_new_messages' filter: thread
      # replies (incl. broadcasts) are skipped by the poller, so comparing
      # against one would be a false-positive stall.
      messages = SlackService.get_channel_history(channel_id, limit: HISTORY_SCAN_LIMIT)
      messages
        .reject { |m| m.thread_ts.present? && m.thread_ts != m.ts }
        .map(&:ts)
        .max
    end
  end
end
