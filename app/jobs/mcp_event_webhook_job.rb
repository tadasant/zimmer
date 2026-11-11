# frozen_string_literal: true

# Fires one event an MCP server POSTed to Webhooks::McpEventsController, through the same claim and
# fire the poller uses (McpEvents::Firing). The controller acknowledges the delivery once this job
# is enqueued, so the server's ~5 second delivery timeout never waits on a spawn.
#
# Whatever does not fire here, the poll still sees. An event held by burst control or a pending
# session, one whose spawn raised, or one that arrives while the trigger is bursting gives its
# claim back (or never takes one). The condition's poll cursor has not moved past it, because only
# a settled poll moves the cursor, so the next poll fires it. Push makes an event fire sooner, and
# polling is what keeps delivery at-least-once.
class McpEventWebhookJob < ApplicationJob
  queue_as :default

  def perform(subscription_id, raw_occurrence)
    subscription = McpEventWebhookSubscription.find_by(id: subscription_id)
    return if subscription.nil? || !subscription.live?

    condition = subscription.trigger_condition
    occurrence = McpEvents::Client.occurrence_from(raw_occurrence)
    return if occurrence.nil?

    begin
      McpEvents::Firing.ensure_fireable!(condition.trigger)
    rescue McpEvents::Firing::UnfireableTrigger => e
      McpEvents::Firing.report(condition, e, source: self.class.name)
      return
    end
    # See McpEventTriggerPollerJob#process_condition: retrying into an open burst holds it open.
    return if condition.trigger.bursting?

    # The row's own copy of the subscription: an edit landing before the lock rolls the fire back.
    McpEvents::Firing.settle(condition, [ subscription.server, subscription.event_name, subscription.arguments ], occurrence,
      via: "mcp_event_webhook", log_tag: self.class.name)
  end
end
