# frozen_string_literal: true

# Who is signed in to the web UI, for the one web page that has to know:
# `/oauth/authorize`, which issues a credential for `/mcp` and must name the
# human who consented.
#
# This is a seam. Zimmer's web UI has no sign-in today (docs: auth/overview), so
# outside development and test there is nobody to name and `current_web_user_email`
# is nil — and /oauth/authorize, seeing nil, issues nothing. The Google sign-in
# gate (tadasant/zimmer, "Google OAuth gate") fills this in from its signed-in
# identity; with the gate on, a browser that is not signed in never reaches the
# action at all, because the gate's own before_action sends it through sign-in
# and back.
#
# Development and test may name a user with ZIMMER_DEV_WEB_USER_EMAIL, so the
# flow can be exercised end to end on a laptop. No other environment reads it.
module WebUserIdentity
  extend ActiveSupport::Concern

  DEV_EMAIL_ENV = "ZIMMER_DEV_WEB_USER_EMAIL"

  private

  # @return [String, nil] the signed-in human's email
  def current_web_user_email
    return ENV[DEV_EMAIL_ENV].presence if Rails.env.local?

    nil
  end
end
