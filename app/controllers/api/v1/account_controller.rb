# frozen_string_literal: true

# Who the caller is, and signing out everywhere: the Settings page's Sign-in card
# and its Deployment Information, for the iOS app.
#
# The read is open to any credential the API takes, and says which it was: the
# app's grant names a person and how they let the app act; an API key names a
# key. Signing out everywhere is a person's act, so it takes the app's sign-in
# acting as you, as `authorize_merge` does.
class Api::V1::AccountController < Api::BaseController
  accepts_native_app_tokens

  before_action :require_a_person_on_the_app, only: [ :sign_out_everywhere ]

  # GET /api/v1/me
  #
  # `me` is the credential this request came in on. For the app's token:
  # `email`, `privilege` (`act_as_human` or `relay_only`, as the connections list
  # labels it), `acts_as_you`, and `grant_id` — the id of the caller's own row in
  # `GET /oauth_grants`, which also flags it `current`. For an API key: the key's
  # name and grant, and no person.
  #
  # `web_sign_in` is what the Settings page's Sign-in card shows for that email:
  # nil when web sign-in is not configured on this deployment, or when nobody
  # with that email has signed in to the web UI. `totp_enrolled_at` and
  # `recovery_codes_remaining` are nil until an authenticator stands, as the card
  # omits them.
  #
  # `deployment` is the page's Deployment Information: the git commit, branch
  # and commit date this process booted from, and its environment.
  def show
    render json: { me: me_json, web_sign_in: web_sign_in_json, deployment: deployment_json }
  end

  # POST /api/v1/sign_out_everywhere
  #
  # What the Sign-in card's "Sign out everywhere" does: every browser signed in
  # to the web UI as the caller's email is signed out at its next request, its
  # trusted devices are forgotten, and its live-update connections are closed.
  # The web does that to the browser pressing the button too, so this revokes
  # the caller's own connection as well: the next request on this token is a
  # 401, and the app has to sign in again. Other phones signed in as the same
  # person keep their connections; revoke them from `GET /oauth_grants`.
  def sign_out_everywhere
    grant = native_app_grant
    identities = WebIdentity.where(email: grant.user_email).to_a
    identities.each(&:sign_out_everywhere!)
    Rails.logger.warn("[web_auth] signed out everywhere for #{grant.user_email} " \
      "(web_identity_ids=#{identities.map(&:id).inspect}) from #{native_app_actor}")
    grant.revoke!("signed out everywhere from #{native_app_actor}")

    render json: {
      signed_out_everywhere: true,
      web_sign_ins_ended: identities.size,
      this_connection_revoked: true,
      message: "Signed out on every device. This sign-in is revoked too; sign in again to keep using the app."
    }
  end

  private

  def me_json
    if native_app_request?
      {
        authenticated_as: "native_app",
        email: native_app_grant.user_email,
        privilege: native_app_grant.privilege,
        acts_as_you: native_app_grant.acts_as_human?,
        grant_id: native_app_grant.id,
        api_key: nil
      }
    else
      key = @authenticated_api_key
      {
        authenticated_as: "api_key",
        email: nil,
        privilege: nil,
        acts_as_you: false,
        grant_id: nil,
        api_key: { id: key.id, name: key.name, source: key.source, grant: key.effective_grant }
      }
    end
  end

  # The card reads the signed-in browser's identity. The app has no browser, so
  # the identity is the one that signed in with the grant's email — the most
  # recent, if that address has ever been recycled onto a second Google account.
  # The card is the signed-in browser's; a relay-only grant is not that person's
  # sign-in, so it gets no recovery-code count.
  def web_sign_in_json
    return nil unless native_app_request? && native_app_grant.acts_as_human?

    configuration = web_auth_configuration
    return nil unless configuration&.enabled?

    identity = WebIdentity.where(email: native_app_grant.user_email).order(last_signed_in_at: :desc, id: :desc).first
    return nil unless identity

    enrolled = identity.totp_enrolled?(reset_before: configuration.second_factor_reset_before)
    {
      email: identity.email,
      name: identity.name,
      last_signed_in_at: identity.last_signed_in_at,
      totp_required: configuration.totp_required?,
      totp_enrolled_at: enrolled ? identity.totp_enrolled_at : nil,
      recovery_codes_remaining: enrolled ? identity.recovery_codes_remaining : nil
    }
  end

  # The settings store can be unreachable; the page's card then has nothing to
  # show either. A read that fails costs the card, not the identity.
  def web_auth_configuration
    WebAuth::Configuration.current
  rescue WebAuth::Configuration::Unavailable => e
    Rails.logger.warn("[web_auth] /api/v1/me could not read the web sign-in configuration: #{e.message.to_s.truncate(200)}")
    nil
  end

  def deployment_json
    { git: DeploymentInfoService.git_info, environment: DeploymentInfoService.environment_info }
  end
end
