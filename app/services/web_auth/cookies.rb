# frozen_string_literal: true

module WebAuth
  # The two cookies that remember a person, both encrypted with
  # secret_key_base, HttpOnly, and SameSite=Lax.
  #
  # Both carry `Secure` whenever the request is https, including https that a
  # local TLS-terminating proxy reports in X-Forwarded-Proto.
  #
  # **The sign-in cookie** says "this browser is signed in as identity N". It
  # rolls: every request at least REFRESH_INTERVAL after the last re-issue
  # writes it again with a fresh expiry, so a browser used at least once per
  # session TTL (90 days by default) never sees the login page again. The
  # expiry is checked from the payload as well as left to the browser.
  #
  # It stops counting when:
  #   * the identity row is gone, or its session_generation moved (sign out everywhere),
  #   * the identity's Workspace domain is no longer allowed,
  #   * the deployment requires a TOTP second factor and this cookie was issued without one.
  #
  # **The trusted-device cookie** says "this browser passed the second factor
  # for identity N's current authenticator". At the next Google sign-in, after
  # the sign-in cookie has lapsed or the person signed out, it skips the code
  # prompt. It is tied to the enrollment's timestamp and the session
  # generation, so a new authenticator, signing out everywhere, or a
  # deployment-wide second-factor reset voids every one of them.
  module Cookies
    module_function

    SIGN_IN = :zimmer_web_sign_in
    TRUSTED_DEVICE = :zimmer_trusted_device
    REFRESH_INTERVAL = 1.day

    # @return [WebIdentity, nil]
    def signed_in_identity(cookies, configuration, at: Time.current)
      data = read(cookies, SIGN_IN)
      return nil unless data

      refreshed_at = Time.at(data["r"].to_i)
      return nil if refreshed_at + configuration.session_ttl <= at
      return nil if configuration.totp_required? && data["f"] != "totp"

      identity = WebIdentity.find_by(id: data["id"])
      return nil unless identity
      return nil unless identity.session_generation == data["g"]
      return nil unless configuration.domain_allowed?(identity.hosted_domain)

      identity
    end

    # @param factor [String] "totp" when the browser passed Zimmer's second
    #   factor (directly or through a trusted-device cookie), "none" otherwise
    def sign_in(cookies, identity, configuration, factor:, at: Time.current)
      write(cookies, SIGN_IN, { "id" => identity.id, "g" => identity.session_generation, "f" => factor, "r" => at.to_i }, at + configuration.session_ttl)
    end

    # Re-issue the cookie with a fresh expiry, at most once per REFRESH_INTERVAL.
    def refresh_if_due(cookies, configuration, at: Time.current)
      data = read(cookies, SIGN_IN)
      return unless data && Time.at(data["r"].to_i) + REFRESH_INTERVAL <= at

      write(cookies, SIGN_IN, data.merge("r" => at.to_i), at + configuration.session_ttl)
    end

    def sign_out(cookies)
      cookies.delete(SIGN_IN)
    end

    def trust_device(cookies, identity, configuration, at: Time.current)
      write(cookies, TRUSTED_DEVICE, { "id" => identity.id, "g" => identity.session_generation, "e" => enrollment_stamp(identity) }, at + configuration.trusted_device_ttl)
    end

    def trusted_device?(cookies, identity, configuration)
      data = read(cookies, TRUSTED_DEVICE)
      return false unless data && data["id"] == identity.id && data["g"] == identity.session_generation
      return false unless identity.totp_enrolled?(reset_before: configuration.second_factor_reset_before)

      data["e"] == enrollment_stamp(identity)
    end

    def enrollment_stamp(identity) = identity.totp_enrolled_at&.utc&.iso8601(6)

    def read(cookies, name)
      data = cookies.encrypted[name]
      data.is_a?(Hash) ? data : nil
    end

    # `secure` follows the request rather than `force_ssl`: behind a
    # TLS-terminating local proxy (cloudflared, kamal-proxy) the request is
    # https by its X-Forwarded-Proto even on a deployment that runs with
    # DISABLE_SSL, and a sign-in cookie must never travel over plain HTTP.
    def write(cookies, name, value, expires)
      cookies.encrypted[name] = { value: value, expires: expires, httponly: true, same_site: :lax, secure: cookies.request.ssl? }
    end
  end
end
