# frozen_string_literal: true

# Counts every controller response by surface and status class for
# SecurityTelemetry, so a run of 401s, 403s or 404s against /api or /mcp shows up
# as a rate on /health/export_diagnostics.
#
# `process_action.action_controller` fires once per request that reached a
# controller, unrouted paths included (the catch-all route sends them to
# ErrorsController). A request that raised has no `status` in the payload yet;
# the status it will be answered with is the one ShowExceptions maps the
# exception to, which is what Rails' own request log line reports too.
#
# What it does not see: a request refused by middleware before any controller
# runs (host authorization, a malformed request Rack rejects). See
# docs/operate/observability.md.
ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
  status = payload[:status]
  if status.nil? && (exception = payload[:exception_object])
    status = ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
  end

  SecurityTelemetry.record_response(payload[:path].to_s.split("?", 2).first, status)
rescue StandardError => e
  Rails.logger.error("[SecurityTelemetry] could not record a response: #{e.class}")
end
