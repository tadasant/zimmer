# frozen_string_literal: true

# Cron job (every 5 minutes) that checks whether MCP servers can actually reach
# the elicitation endpoint Zimmer hands them.
#
# This exists because the failure it watches for is invisible from both ends. An
# MCP server whose approval POST never lands falls back to a redacted value, and
# the agent cannot tell "you were denied" from "the gate is down" — the observed
# consequence being an agent that read the secret another way instead. Zimmer
# never hears from a request that was never delivered, so the only way to know is
# to try the endpoint ourselves, from the host agents run on.
#
# The recorded status feeds OrchestratorSystemPromptBuilder, which warns the agent
# in its own prompt when the gate is down.
#
# Queue placement — `:pollers`, like the other periodic monitors.
class ElicitationEndpointHealthCheckJob < ApplicationJob
  queue_as :pollers

  # Singleton: overlapping cron ticks must never stack a second probe on a slow one.
  good_job_control_concurrency_with(
    key: -> { "elicitation_endpoint_health_check" },
    total_limit: 1
  )

  ALERT_DEDUP_KEY = "elicitation_endpoint_unreachable"

  # @param endpoint [Class] injectable for tests; defaults to the real probe.
  def perform(endpoint: ElicitationEndpoint)
    was_unreachable = endpoint.status&.dig("reachable") == false
    stored = endpoint.record(endpoint.probe)

    if stored["reachable"]
      Rails.logger.info("[ElicitationEndpointHealthCheckJob] elicitation endpoint reachable: #{stored['detail']}") if was_unreachable
      return
    end

    # Warn on every failed tick, not just the transition: unlike a banner, nothing
    # else keeps saying this, and a gate that silently fails closed is exactly the
    # kind of thing that stays broken for weeks.
    Rails.logger.warn("[ElicitationEndpointHealthCheckJob] elicitation endpoint unreachable at #{stored['url']}: #{stored['detail']}")

    return if was_unreachable

    AlertService.raise_alert(
      "MCP approval gate unreachable",
      details: "MCP servers cannot reach #{stored['url']}, so every gated reveal fails closed and returns a redacted value with no error. #{stored['detail']}",
      source: "ElicitationEndpointHealthCheckJob",
      dedup_key: ALERT_DEDUP_KEY
    )
  end
end
