# frozen_string_literal: true

# The state the two sign-in controllers share between Google's callback and the
# second-factor page: who has passed Google but not yet the second factor, and
# how a sign-in finishes.
module WebSignInFlow
  extend ActiveSupport::Concern

  PENDING_KEY = :web_auth_pending
  # How long after Google a browser has to finish the second factor.
  PENDING_TTL = 15.minutes

  included do
    layout "web_auth"
  end

  private

  def remember_pending_identity(identity)
    session[PENDING_KEY] = { "id" => identity.id, "at" => Time.current.to_i }
  end

  # The identity that passed Google in this browser and still owes the second
  # factor, or nil.
  def pending_identity
    data = session[PENDING_KEY]
    return nil unless data.is_a?(Hash) && Time.at(data["at"].to_i) + PENDING_TTL > Time.current

    WebIdentity.find_by(id: data["id"])
  end

  # Set the sign-in cookie and send the browser where it was going. The Rails
  # session is reset first, so nothing a signed-out browser put in it survives
  # (session fixation), except where it was going.
  def finish_sign_in(identity, factor:, trust_device: false)
    return_to = safe_return_to(session[WebSignInRequired::RETURN_TO_KEY])
    reset_session
    WebAuth::Cookies.sign_in(cookies, identity, web_auth_configuration, factor: factor)
    WebAuth::Cookies.trust_device(cookies, identity, web_auth_configuration) if trust_device
    Rails.logger.info("[web_auth] signed in #{identity.email} (web_identity_id=#{identity.id}, factor=#{factor}, trusted_device=#{trust_device})")
    return_to
  end

  # Only a path on this host. "//evil.example" is a host, not a path.
  def safe_return_to(value)
    path = value.to_s
    path.start_with?("/") && !path.start_with?("//") && !path.start_with?("/\\") ? path : "/"
  end

  def second_factor_reset_before
    web_auth_configuration.second_factor_reset_before
  end
end
