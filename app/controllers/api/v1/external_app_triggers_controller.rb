# frozen_string_literal: true

# A Zimmer plugin's REST surface — the same two things as its MCP tools, with the
# same bodies (ExternalApps::Presenter):
#
#   GET  /api/v1/external_app/triggers              the triggers this key may invoke
#   POST /api/v1/external_app/triggers/:id/invoke   invoke one, with { "variables": {...} }
#
# Opened only by a key with the `external_app` grant, for an enabled plugin
# (ExternalAppAuthentication). Every other /api/v1 route refuses that key.
class Api::V1::ExternalAppTriggersController < Api::BaseController
  include ExternalAppAuthentication

  # Outcome → HTTP status. Only `fired` is a 201: `burst_notice` hands back a
  # session, but not the one that was asked for.
  STATUSES = {
    fired: :created,
    burst_notice: :too_many_requests,
    burst_suppressed: :too_many_requests,
    pending_session: :conflict,
    not_reusable: :unprocessable_entity,
    not_found: :not_found,
    invalid_variables: :unprocessable_entity,
    not_invokable: :unprocessable_entity,
    error: :unprocessable_entity
  }.freeze

  def index
    render json: ExternalApps::Presenter.triggers_json(current_external_app)
  end

  def invoke
    result = ExternalApps::InvokeTrigger.call(
      external_app: current_external_app,
      trigger_id: params[:id],
      variables: request.request_parameters["variables"]
    )
    body = ExternalApps::Presenter.invocation_json(result, base_url: request.base_url)
    status = STATUSES.fetch(result.outcome)

    if result.fired?
      render json: body, status: status
    else
      # The API's one error envelope, with the invocation's fields beside it.
      render_api_error(result.outcome.to_s.humanize, result.message, status: status, **body.except(:message))
    end
  end
end
