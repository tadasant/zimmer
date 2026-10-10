# frozen_string_literal: true

# Zimmer's iOS app registering a phone for push notifications (ApnsDevice,
# ApnsService).
#
#   POST   /api/v1/apns_devices          {token, environment, device_name?, app_version?}
#   DELETE /api/v1/apns_devices/:token
#
# Registration is an upsert on the token, so the app registers on every launch
# and a re-registration revives a disabled row. A registration made with the
# app's bearer token is tied to its OAuth grant, so revoking the phone's
# connection also stops its pushes. Deleting is how the app unregisters on
# sign-out; an unknown token is a 204 too, because the outcome is the same.
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

  def destroy
    ApnsDevice.where(token: params[:token].to_s.downcase).delete_all
    head :no_content
  end

  private

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
