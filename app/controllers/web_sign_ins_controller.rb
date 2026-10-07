# frozen_string_literal: true

# Google sign-in for the web UI: the login page, the hop to Google, the
# callback, and signing out. See WebAuth::GoogleOauth for what is verified and
# docs/auth/web-sign-in.md for the posture as a whole.
class WebSignInsController < ApplicationController
  include WebSignInFlow

  OAUTH_KEY = :web_auth_oauth
  # How long the round trip through Google's consent screen may take.
  OAUTH_TTL = 15.minutes

  allow_signed_out_access except: :destroy_everywhere
  before_action :require_enabled_gate, except: :destroy

  # GET /login
  def new
    return redirect_to(root_path) if WebAuth::Cookies.signed_in_identity(cookies, web_auth_configuration)

    @configuration = web_auth_configuration
  end

  # POST /auth/google — a POST carrying the CSRF token, so another site cannot
  # start a sign-in in your browser.
  def create
    return render_login_error("Sign-in is not set up correctly: #{web_auth_configuration.problems.to_sentence}.", status: :service_unavailable) unless web_auth_configuration.usable?

    state = SecureRandom.urlsafe_base64(24)
    verifier = SecureRandom.urlsafe_base64(48)
    session[OAUTH_KEY] = { "state" => state, "verifier" => verifier, "at" => Time.current.to_i }

    redirect_to WebAuth::GoogleOauth.new(web_auth_configuration).authorization_url(state: state, code_verifier: verifier),
      allow_other_host: true
  end

  # GET /auth/google/callback
  def callback
    flow = session.delete(OAUTH_KEY)
    return render_login_error("Google did not sign you in (#{params[:error].to_s.truncate(80)}).") if params[:error].present?
    return render_login_error("That sign-in did not start in this browser, or took too long. Start again.") unless valid_flow?(flow)

    google_identity = WebAuth::GoogleOauth.new(web_auth_configuration).complete(code: params[:code].to_s, code_verifier: flow["verifier"])
    identity = WebIdentity.sign_in_from_google!(google_identity)

    if !web_auth_configuration.totp_required?
      redirect_to finish_sign_in(identity, factor: "none")
    elsif identity.totp_enrolled?(reset_before: second_factor_reset_before) && WebAuth::Cookies.trusted_device?(cookies, identity, web_auth_configuration)
      redirect_to finish_sign_in(identity, factor: "totp")
    else
      remember_pending_identity(identity)
      redirect_to identity.totp_enrolled?(reset_before: second_factor_reset_before) ? second_factor_path : second_factor_setup_path
    end
  rescue WebAuth::GoogleOauth::Rejected => e
    Rails.logger.warn("[web_auth] refused Google sign-in from #{request.remote_ip}: #{e.message}")
    render_login_error(e.message, status: :forbidden)
  rescue WebAuth::GoogleOauth::ExchangeFailed => e
    Rails.logger.warn("[web_auth] Google sign-in failed: #{e.message}")
    render_login_error("Google sign-in did not complete. Try again.", status: :bad_gateway)
  end

  # DELETE /logout — this browser only. It keeps its trusted-device cookie, so
  # the next sign-in asks for Google and nothing more.
  def destroy
    WebAuth::Cookies.sign_out(cookies)
    reset_session
    redirect_to login_path, notice: "Signed out."
  end

  # POST /logout/everywhere — every browser signed in as you, this one included.
  def destroy_everywhere
    current_web_identity&.sign_out_everywhere!
    WebAuth::Cookies.sign_out(cookies)
    reset_session
    redirect_to login_path, notice: "Signed out on every device."
  end

  private

  def require_enabled_gate
    redirect_to root_path unless web_auth_configuration.enabled?
  end

  def valid_flow?(flow)
    flow.is_a?(Hash) &&
      Time.at(flow["at"].to_i) + OAUTH_TTL > Time.current &&
      params[:state].present? &&
      ActiveSupport::SecurityUtils.secure_compare(flow["state"].to_s, params[:state].to_s)
  end

  def render_login_error(message, status: :unprocessable_entity)
    @configuration = web_auth_configuration
    @error = message
    render :new, status: status
  end
end
