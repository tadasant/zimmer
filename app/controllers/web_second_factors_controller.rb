# frozen_string_literal: true

# The second step of web sign-in: an authenticator code (TOTP) or a recovery
# code, and setting up the authenticator in the first place.
#
# Two kinds of browser reach these pages:
#   * one that has just passed Google and still owes the second factor
#     (WebSignInFlow#pending_identity), and
#   * one that is fully signed in and is replacing its authenticator (setup
#     only). The old authenticator keeps working until the new one is confirmed.
class WebSecondFactorsController < ApplicationController
  include WebSignInFlow

  allow_signed_out_access
  before_action :require_totp_mode
  # The setup page shows a TOTP secret and the confirmation shows recovery
  # codes: neither belongs in a browser or proxy cache.
  before_action { response.headers["Cache-Control"] = "no-store" }
  before_action :load_verifying_identity, only: %i[new create]
  before_action :load_enrolling_identity, only: %i[setup confirm_setup]

  # GET /login/second_factor
  def new
  end

  # POST /login/second_factor
  def create
    case @identity.verify_second_factor!(params[:code])
    when :totp
      redirect_to finish_sign_in(@identity, factor: "totp", trust_device: trust_device?)
    when :recovery_code
      remaining = @identity.recovery_codes_remaining
      Rails.logger.warn("[web_auth] #{@identity.email} signed in with a recovery code (#{remaining} left)")
      return_to = finish_sign_in(@identity, factor: "totp", trust_device: trust_device?)
      redirect_to return_to, notice: "Signed in with a recovery code. #{remaining} left. " \
        "If you lost your authenticator, set up a new one in Settings."
    when :locked
      minutes = ((@identity.second_factor_locked_until - Time.current) / 60.0).ceil
      @error = "Too many wrong codes. Try again in #{helpers.pluralize(minutes, "minute")}."
      render :new, status: :too_many_requests
    else
      @error = "That code did not match. Check the time on your phone, or use a recovery code."
      render :new, status: :unprocessable_entity
    end
  end

  # GET /login/second_factor/setup
  def setup
    @secret = @identity.pending_totp_secret!
  end

  # POST /login/second_factor/setup
  def confirm_setup
    @recovery_codes = @identity.confirm_totp_enrollment!(params[:code])
    if @recovery_codes.nil?
      @secret = @identity.pending_totp_secret!
      @error = "That code did not match. Make sure you added the key shown here, then enter the code it shows now."
      return render :setup, status: :unprocessable_entity
    end

    Rails.logger.info("[web_auth] #{@identity.email} set up an authenticator (web_identity_id=#{@identity.id})")
    @return_to = finish_sign_in(@identity, factor: "totp", trust_device: true)
    render :recovery_codes
  end

  private

  def require_totp_mode
    redirect_to root_path unless web_auth_configuration.enabled? && web_auth_configuration.totp_required?
  end

  def load_verifying_identity
    @identity = pending_identity
    return redirect_to(login_path, alert: "Sign in with Google first.") unless @identity
    redirect_to second_factor_setup_path unless @identity.totp_enrolled?(reset_before: second_factor_reset_before)
  end

  def load_enrolling_identity
    signed_in = WebAuth::Cookies.signed_in_identity(cookies, web_auth_configuration)
    @replacing = signed_in.present?
    @identity = signed_in || pending_identity
    return redirect_to(login_path, alert: "Sign in with Google first.") unless @identity
    # A browser that has only passed Google may set up a factor only when there
    # is none standing. Otherwise anyone holding the Google account could
    # replace the authenticator and walk straight past it.
    if !@replacing && @identity.totp_enrolled?(reset_before: second_factor_reset_before)
      redirect_to second_factor_path
    end
  end

  def trust_device?
    params[:trust_device] == "1"
  end
end
