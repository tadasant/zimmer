# frozen_string_literal: true

# Cron job (every minute) that probes the worker's primary DNS resolver and
# drives the "network egress degraded" banner. See EgressHealthCheck for why the
# primary resolver is probed directly rather than via ordinary resolution.
#
# Queue placement — deliberately `:pollers`, not `:default`: an egress monitor
# must keep firing even when the `default` queue is backed up, and it shares the
# isolated poller scheduler with the other periodic monitors.
class EgressHealthCheckJob < ApplicationJob
  queue_as :pollers

  # Singleton: overlapping cron ticks must never stack a second probe on top of a
  # slow one. Mirrors the other periodic monitors.
  good_job_control_concurrency_with(
    key: -> { "egress_health_check" },
    total_limit: 1
  )

  # @param check [EgressHealthCheck] injectable for tests (drive the real record/
  #   cache path with a fake DNS boundary) — the default runs the real probe.
  def perform(check: EgressHealthCheck.new)
    previous = EgressHealthCheck.status
    stored = EgressHealthCheck.record(check.probe, previous: previous)

    was_degraded = previous&.dig("status") == "degraded"
    now_degraded = stored["status"] == "degraded"

    if now_degraded && !was_degraded
      # The banner goes up now, but a banner is passive — page a human too so an
      # unattended outage (the exact "silently broke for hours" failure mode this
      # exists to close) reaches someone even with no Zimmer tab open. .error, not
      # .warn: the ERROR record is what pages. Won't self-resolve without infra
      # action, so it fires once on the transition; steady-state degraded ticks stay
      # quiet (the banner is the ongoing signal) to avoid per-minute noise.
      Rails.logger.error("[EgressHealthCheckJob] network egress degraded: #{stored["detail"]}")
      ErrorReporter.report_message(
        "Network egress degraded",
        level: :error,
        context: {
          source: "EgressHealthCheckJob",
          details: "The worker's primary DNS resolver can't resolve public hostnames — new agent logins and sessions will fail. #{stored["detail"]}"
        }
      )
    elsif was_degraded && !now_degraded
      Rails.logger.info("[EgressHealthCheckJob] network egress recovered: #{stored["detail"]}")
    end
  end
end
