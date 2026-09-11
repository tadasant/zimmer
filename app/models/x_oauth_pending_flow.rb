# frozen_string_literal: true

# One X (Twitter) OAuth consent in progress: the state carried between sending the
# operator to X and exchanging the code X sends back (#852).
#
# Lifecycle:
# - Created by Supervisor::XOauthAuthorizationsController#create (.start!), which
#   then sends the operator to #authorization_url.
# - Claimed by the hosted callback, or by the paste-back form when the redirect URI
#   is one Zimmer does not serve (.claim!). Claiming deletes the row, so a state
#   works exactly once: a replayed callback, a double-submitted paste, and a second
#   tab all find nothing.
# - Replaced when a flow for the same credential is started again, and swept once
#   expired whenever any flow starts. An abandoned consent therefore leaves at most
#   one verifier behind, for at most EXPIRATION_DURATION plus the time until the
#   next start.
#
# The row holds no client secret. X_OAUTH_CLIENT_ID / X_OAUTH_CLIENT_SECRET stay in
# credentials and are read at exchange time, as the refresh path reads them.
class XOauthPendingFlow < ApplicationRecord
  # Long enough to sign in to X and approve, or to copy a redirect URL back into
  # the paste-back form. Short, because the verifier is the one secret that turns an
  # intercepted authorization code into a live credential.
  EXPIRATION_DURATION = 30.minutes

  # What SecretsInterpolator resolves as ${NAME} in .mcp.json: an upper-case
  # environment-variable name, nothing that needs quoting.
  ENV_VAR_FORMAT = /\A[A-Z_][A-Z0-9_]*\z/

  # A claim that did not produce a flow. The message is safe to show the operator.
  class ClaimError < StandardError; end

  validates :state, presence: true, uniqueness: true
  validates :code_verifier, presence: true
  validates :redirect_uri, presence: true
  validates :account_key, presence: true
  validates :access_token_env_var, presence: true,
    format: { with: ENV_VAR_FORMAT, message: "must be an upper-case environment variable name, like X_OAUTH_ACCESS_TOKEN" }
  validates :expires_at, presence: true
  validate :identity_agrees_with_stored_credential

  scope :expired, -> { where(expires_at: ..Time.current) }

  # Starts a consent flow for the credential vended as access_token_env_var,
  # replacing any flow already in progress for it.
  #
  # @return [XOauthPendingFlow] the saved flow
  # @raise [ActiveRecord::RecordInvalid] when the identity is unusable
  def self.start!(account_key:, access_token_env_var:, redirect_uri: XOauthBootstrap.default_redirect_uri)
    account_key = account_key.to_s.strip
    access_token_env_var = access_token_env_var.to_s.strip

    transaction do
      expired.delete_all
      where(access_token_env_var: access_token_env_var).delete_all
      create!(
        account_key: account_key,
        access_token_env_var: access_token_env_var,
        redirect_uri: redirect_uri,
        state: XOauthBootstrap.generate_state,
        code_verifier: XOauthBootstrap.generate_verifier,
        expires_at: EXPIRATION_DURATION.from_now
      )
    end
  end

  # Takes the flow a callback's `state` names, exactly once.
  #
  # The conditional DELETE is the claim. Two requests racing on one state both
  # find the row, and only the one whose DELETE removes it gets it back. An expired
  # flow is deleted too, then refused, so it cannot be tried again.
  #
  # The returned record is no longer in the database; its attributes (the verifier,
  # the identity) are still readable, which is all the exchange needs.
  #
  # @return [XOauthPendingFlow]
  # @raise [ClaimError] when state is blank, unknown, already claimed, or expired
  def self.claim!(state)
    raise ClaimError, "The callback carried no state parameter." if state.blank?

    flow = find_by(state: state.to_s)
    claimed = flow && where(id: flow.id).delete_all == 1
    raise ClaimError, "No X authorization in progress matches this callback. It may have been used already, replaced by a newer one, or expired." unless claimed
    raise ClaimError, "This X authorization expired. Start it again." if flow.expired?

    flow
  end

  # Reads the parameters out of a redirect URL the operator pasted back, such as
  # "http://localhost:8080/callback?state=…&code=…".
  #
  # A bare code is refused on purpose. The state is what ties a code to the flow
  # whose verifier can redeem it, so the paste-back goes through the same claim as
  # the hosted callback: the pasted URL's state picks the flow, and a state no live
  # flow holds is refused.
  #
  # @return [Hash, nil] state:, code:, error:, error_description: — or nil when
  #   the value carries no state
  def self.parse_redirect(pasted)
    value = pasted.to_s.strip
    query = value.include?("?") ? value.split("?", 2).last : value
    params = URI.decode_www_form(query.split("#", 2).first.to_s).to_h
    return nil if params["state"].blank?

    {
      state: params["state"],
      code: params["code"],
      error: params["error"],
      error_description: params["error_description"]
    }
  rescue ArgumentError
    nil
  end

  def expired?
    expires_at <= Time.current
  end

  # True when X will send the operator somewhere Zimmer does not listen (the
  # localhost URI the X app has registered), so the redirect URL has to be
  # pasted back by hand. False when the redirect URI is Zimmer's own callback.
  def manual?
    XOauthBootstrap.manual_completion_required?(redirect_uri)
  end

  # The X consent URL for this flow.
  def authorization_url(client_id:)
    XOauthBootstrap.authorize_url(
      client_id: client_id, verifier: code_verifier, state: state, redirect_uri: redirect_uri
    )
  end

  private

  # XOauthBootstrap.complete! looks the credential up by env var and keeps the
  # account_key already stored on it, and account_key is unique. So a flow whose
  # pair half-matches a stored credential would either get all the way through X's
  # consent and then fail to save, or save under a different account than the one
  # the operator typed. Refuse both before the operator is sent to X.
  def identity_agrees_with_stored_credential
    return if account_key.blank? || access_token_env_var.blank?

    by_account = XOauthCredential.find_by(account_key: account_key)
    if by_account && by_account.access_token_env_var != access_token_env_var
      errors.add(:account_key, "#{account_key} is already vended as #{by_account.access_token_env_var}. Re-authorize that credential instead.")
    end

    by_env_var = XOauthCredential.find_by(access_token_env_var: access_token_env_var)
    if by_env_var && by_env_var.account_key != account_key
      errors.add(:access_token_env_var, "#{access_token_env_var} already vends #{by_env_var.account_key}. Re-authorize that credential instead.")
    end
  end
end
