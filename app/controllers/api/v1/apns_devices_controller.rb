# frozen_string_literal: true

# Zimmer's iOS app registering a phone for push notifications (ApnsDevice,
# ApnsService).
#
#   POST   /api/v1/apns_devices          {token, environment, device_name?, app_version?}
#   DELETE /api/v1/apns_devices/:token
#   POST   /api/v1/apns_devices/failure  {stage, error?, environment?, device_name?, app_version?}
#
# Registration is an upsert on the token, so the app registers on every launch
# and a re-registration revives a disabled row. A registration made with the
# app's bearer token is tied to its OAuth grant, so revoking the phone's
# connection also stops its pushes. Deleting is how the app unregisters on
# sign-out, and it reaches only that grant's own devices; an unknown token is a
# 204 too, because the outcome is the same.
#
# A phone that does not end up with a row has failed somewhere this server
# cannot see: the person declined the permission prompt, APNs refused to issue
# a token, or the registration POST itself was refused. The app reports each of
# those to `failure`, and every refusal this controller renders, auth included,
# is logged at WARN under `[apns]` so it reaches the shipped logs; request lines
# are INFO and are not shipped.
class Api::V1::ApnsDevicesController < Api::BaseController
  accepts_native_app_tokens

  def create
    device = ApnsDevice.register!(
      token: params.require(:token),
      environment: params.require(:environment),
      device_name: params[:device_name].presence&.to_s,
      app_version: params[:app_version].presence&.to_s,
      grant: @native_app_grant
    )
    render json: { apns_device: device_json(device) }, status: :created
  rescue ActionController::ParameterMissing => e
    render_api_error("Missing parameter", "#{e.param} is required", status: :unprocessable_entity)
  end

  # What the app saw go wrong on the phone, logged at WARN. The app sends it
  # best-effort and ignores the answer.
  def failure
    stage = params.require(:stage).to_s
    unless FAILURE_STAGES.include?(stage)
      return render_api_error("Invalid parameter", "stage must be one of #{FAILURE_STAGES.join(', ')}",
                              status: :unprocessable_entity)
    end

    Rails.logger.warn(
      "[apns] registration failed on the phone at #{stage} (#{caller_label}): " \
      "#{params[:error].to_s.squish.truncate(300).presence || 'no detail'}; " \
      "environment=#{params[:environment].to_s.truncate(20).presence || '?'} " \
      "app_version=#{params[:app_version].to_s.truncate(40).presence || '?'} " \
      "device=#{params[:device_name].to_s.truncate(40).presence || '?'}"
    )
    head :no_content
  rescue ActionController::ParameterMissing => e
    render_api_error("Missing parameter", "#{e.param} is required", status: :unprocessable_entity)
  end

  def destroy
    ApnsDevice.where(token: params[:token].to_s.downcase, grant: @native_app_grant).delete_all
    head :no_content
  end

  # Where the phone's registration stops short of a row: `declined` (the
  # notification permission), `apns` (iOS's didFailToRegisterForRemoteNotifications),
  # `register` (the POST to `create` failed).
  FAILURE_STAGES = %w[declined apns register].freeze

  private

  def render_api_error(error, message, status:, **extra)
    Rails.logger.warn(
      "[apns] #{request.request_method} #{request.path} refused " \
      "(#{Rack::Utils.status_code(status)} #{error}) for #{caller_label}: #{Array(message).join(', ')}"
    )
    super
  end

  def caller_label
    native_app_grant ? "grant #{native_app_grant.id}" : "no app grant"
  end

  def device_json(device)
    {
      id: device.id,
      environment: device.environment,
      device_name: device.device_name,
      app_version: device.app_version,
      last_registered_at: device.last_registered_at.iso8601,
      disabled_at: device.disabled_at&.iso8601
    }
  end
end
