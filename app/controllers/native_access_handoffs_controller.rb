# frozen_string_literal: true

# GET /native/access-handoff — gives Zimmer's iOS app the Cloudflare Access
# assertion its own sign-in sheet just earned.
#
# The app's machine calls go to a separate hostname behind its own Access
# application, which admits a request only if it carries a JWT Access minted.
# The app opens this URL on that hostname in the system sign-in sheet; Access
# runs its Google login and forwards the request with `Cf-Access-Jwt-Assertion`.
# This action checks that assertion (NativeAccessAssertion) and redirects to the
# app's private-use scheme with it, where the app checks `state` and keeps the JWT
# for its `cf-access-token` header. The JWT rides in the URL fragment, not the
# query: a fragment is never sent to a server or written to a request log, so the
# credential cannot leak through any hop that follows the redirect.
#
# Deliberately on ActionController::Base, not ApplicationController: no web
# sign-in wall and no CSRF. It hands back only the assertion Cloudflare minted for
# this requester, and every API call still needs Zimmer's own OAuth token besides.
# The redirect target is a constant, never a parameter, so this cannot become an
# open redirector, and nothing here reads `request.host` — the edge rewrites it.
class NativeAccessHandoffsController < ActionController::Base
  CALLBACK_URI = "com.tadasant.zimmer:/access/callback"
  STATE_FORMAT = /\A[A-Za-z0-9._~-]{16,256}\z/

  skip_forgery_protection

  def show
    response.set_header("Cache-Control", "no-store")
    response.set_header("Referrer-Policy", "no-referrer")

    state = params[:state].to_s
    unless state.match?(STATE_FORMAT)
      return render plain: "state must be 16-256 characters of A-Z a-z 0-9 . _ ~ -\n", status: :bad_request
    end

    assertion = request.headers["Cf-Access-Jwt-Assertion"].to_s
    result = NativeAccessAssertion.verify(assertion)
    unless result.ok?
      Rails.logger.info("[native_access] handoff refused from #{request.remote_ip}: assertion #{result.refusal}")
      return render plain: "No valid Cloudflare Access assertion on this request.\n", status: :forbidden
    end

    Rails.logger.info("[native_access] handoff for #{result.claims['email'].inspect}")
    fragment = URI.encode_www_form(cf_access_token: assertion)
    redirect_to "#{CALLBACK_URI}?#{URI.encode_www_form(state: state)}##{fragment}", allow_other_host: true, status: :found
  end
end
