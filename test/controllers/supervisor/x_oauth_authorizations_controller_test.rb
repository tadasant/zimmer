# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "mocha/minitest"

# The X consent flow turns an authorization code into a stored live credential,
# so the paths that matter most are the ones that must NOT reach X's token
# endpoint: no operator credential, and a state that is missing, wrong, expired
# or already used. Each of those asserts that no token request was made and no
# credential was written, not just the status code.
module Supervisor
  class XOauthAuthorizationsControllerTest < ActionDispatch::IntegrationTest
    include SupervisorAuthTestHelper
    include SupervisorAuthTestHelper::AutoBasicAuth
    include XOauthTestHelpers

    TOKEN_BODY = {
      access_token: "fresh-access", refresh_token: "fresh-refresh", expires_in: 7200,
      scope: XOauthCredential::OAUTH_SCOPES
    }.freeze

    setup do
      XOauthCredential.stubs(:client_id).returns("test-client-id")
      XOauthCredential.stubs(:client_secret).returns("test-client-secret")
      @original_redirect = ENV[XOauthBootstrap::REDIRECT_URI_ENV]
      @original_app_host = ENV["APP_HOST"]
      ENV["APP_HOST"] = "zimmer.example.com"
    end

    teardown do
      restore(XOauthBootstrap::REDIRECT_URI_ENV, @original_redirect)
      restore("APP_HOST", @original_app_host)
    end

    def restore(key, value)
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end

    def use_hosted_callback!
      ENV[XOauthBootstrap::REDIRECT_URI_ENV] = XOauthBootstrap.hosted_redirect_uri
    end

    def start_flow(account_key: "tadasayy", env_var: "X_OAUTH_ACCESS_TOKEN")
      post supervisor_x_oauth_authorization_path, params: { account_key: account_key, access_token_env_var: env_var }
      XOauthPendingFlow.find_by!(access_token_env_var: env_var)
    end

    # Runs the block with the token endpoint stubbed and asserts it was never called.
    def refute_token_request
      called = false
      XOauthCredential.stub(:post_token_request, ->(**) { called = true; raise "unexpected token request" }) { yield }
      assert_not called, "the controller sent a token request to X"
    end

    # --- authorization boundary ---

    test "every leg refuses a request without the operator credential" do
      use_hosted_callback!
      flow = start_flow
      no_auth = { "HTTP_AUTHORIZATION" => "" }

      refute_token_request do
        get supervisor_new_x_oauth_authorization_path, headers: no_auth
        assert_response :unauthorized

        post supervisor_x_oauth_authorization_path, headers: no_auth,
          params: { account_key: "someone", access_token_env_var: "X_SOMEONE_TOKEN" }
        assert_response :unauthorized

        get supervisor_x_oauth_callback_path(state: flow.state, code: "a-code"), headers: no_auth
        assert_response :unauthorized

        post supervisor_x_oauth_complete_path, headers: no_auth,
          params: { redirect_response: "http://localhost:8080/callback?state=#{flow.state}&code=a-code" }
        assert_response :unauthorized
      end

      assert XOauthPendingFlow.exists?(flow.id), "an unauthenticated callback consumed the flow"
      assert_equal 1, XOauthPendingFlow.count, "an unauthenticated POST started a flow"
      assert_equal 0, XOauthCredential.count
    end

    test "a wrong operator password is refused on the callback" do
      use_hosted_callback!
      flow = start_flow
      wrong = { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("supervisor", "nope") }

      refute_token_request do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "a-code"), headers: wrong
      end

      assert_response :unauthorized
      assert XOauthPendingFlow.exists?(flow.id)
    end

    # --- starting ---

    test "new renders the connect form with the default env var" do
      get supervisor_new_x_oauth_authorization_path

      assert_response :success
      assert_select "input[name=access_token_env_var][value=X_OAUTH_ACCESS_TOKEN]"
      assert_match XOauthBootstrap.hosted_redirect_uri, response.body
    end

    test "create sends the operator to X with the pending flow's state when the callback is hosted" do
      use_hosted_callback!

      post supervisor_x_oauth_authorization_path, params: { account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN" }

      flow = XOauthPendingFlow.sole
      assert_response :redirect
      location = URI(response.location)
      params = URI.decode_www_form(location.query).to_h
      assert_equal "x.com", location.host
      assert_equal flow.state, params["state"]
      assert_equal "https://zimmer.example.com/supervisor/x_oauth/callback", params["redirect_uri"]
      assert_equal "test-client-id", params["client_id"]
    end

    test "create shows the consent link and paste-back form when X redirects to localhost" do
      ENV.delete(XOauthBootstrap::REDIRECT_URI_ENV)

      post supervisor_x_oauth_authorization_path, params: { account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN" }

      flow = XOauthPendingFlow.sole
      assert_response :success
      assert_select "a[href=?]", flow.authorization_url(client_id: "test-client-id")
      assert_select "form[action=?] textarea[name=redirect_response]", supervisor_x_oauth_complete_path
      assert_select "input[name=flow_state][value=?]", flow.state
    end

    test "create refuses to start without X client credentials" do
      XOauthCredential.stubs(:client_secret).returns(nil)

      post supervisor_x_oauth_authorization_path, params: { account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN" }

      assert_response :unprocessable_entity
      assert_match "X_OAUTH_CLIENT_SECRET", response.body
      assert_equal 0, XOauthPendingFlow.count
    end

    test "create re-renders the form on an unusable identity" do
      post supervisor_x_oauth_authorization_path, params: { account_key: "", access_token_env_var: "not an env var" }

      assert_response :unprocessable_entity
      assert_select "#error_explanation li", minimum: 1
      assert_equal 0, XOauthPendingFlow.count
    end

    # --- the hosted callback ---

    test "callback exchanges the code with the flow's verifier and stores the credential" do
      use_hosted_callback!
      flow = start_flow

      _result, request = with_token_endpoint(code: 200, body: TOKEN_BODY) do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code")
      end

      credential = XOauthCredential.find_by!(access_token_env_var: "X_OAUTH_ACCESS_TOKEN")
      assert_redirected_to supervisor_x_oauth_credential_path(credential)
      assert_equal "tadasayy", credential.account_key
      assert_equal "fresh-access", credential.access_token
      assert_equal "fresh-refresh", credential.refresh_token

      form = URI.decode_www_form(request.body).to_h
      assert_equal "authorization_code", form["grant_type"]
      assert_equal "the-code", form["code"]
      assert_equal flow.code_verifier, form["code_verifier"]
      assert_equal flow.redirect_uri, form["redirect_uri"]
      assert_not XOauthPendingFlow.exists?(flow.id), "the flow survived its own completion"
    end

    test "re-authorizing replaces a dead credential's tokens on the same row" do
      use_hosted_callback!
      existing = XOauthCredential.create!(
        account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
        access_token: "old", refresh_token: nil, last_refresh_error: "permanent: 400 invalid_grant"
      )
      flow = start_flow

      with_token_endpoint(code: 200, body: TOKEN_BODY) do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code")
      end

      existing.reload
      assert_equal 1, XOauthCredential.count
      assert_equal "fresh-refresh", existing.refresh_token
      assert_nil existing.last_refresh_error
    end

    test "callback without a state is refused before anything is sent to X" do
      use_hosted_callback!
      flow = start_flow

      refute_token_request { get supervisor_x_oauth_callback_path(code: "the-code") }

      assert_response :bad_request
      assert_match "no state", response.body
      assert XOauthPendingFlow.exists?(flow.id)
      assert_equal 0, XOauthCredential.count
    end

    test "callback with a state that matches no flow is refused and leaves the real flow alone" do
      use_hosted_callback!
      flow = start_flow

      refute_token_request { get supervisor_x_oauth_callback_path(state: "#{flow.state}x", code: "the-code") }

      assert_response :bad_request
      assert XOauthPendingFlow.exists?(flow.id)
      assert_equal 0, XOauthCredential.count
    end

    test "callback with an expired flow's state is refused and the flow is gone" do
      use_hosted_callback!
      flow = start_flow
      flow.update_column(:expires_at, 1.minute.ago)

      refute_token_request { get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code") }

      assert_response :bad_request
      assert_match "expired", response.body
      assert_not XOauthPendingFlow.exists?(flow.id)
      assert_equal 0, XOauthCredential.count
    end

    test "a replayed callback is refused: the state works once" do
      use_hosted_callback!
      flow = start_flow
      with_token_endpoint(code: 200, body: TOKEN_BODY) do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code")
      end
      assert_response :redirect
      stored = XOauthCredential.sole.attributes

      refute_token_request { get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code") }

      assert_response :bad_request
      assert_equal stored, XOauthCredential.sole.attributes
    end

    test "a flow replaced by a newer one cannot be completed" do
      use_hosted_callback!
      old_flow = start_flow
      start_flow

      refute_token_request { get supervisor_x_oauth_callback_path(state: old_flow.state, code: "the-code") }

      assert_response :bad_request
      assert_equal 0, XOauthCredential.count
    end

    test "an access_denied redirect ends the flow without a token request" do
      use_hosted_callback!
      flow = start_flow

      refute_token_request do
        get supervisor_x_oauth_callback_path(state: flow.state, error: "access_denied", error_description: "The user denied")
      end

      assert_response :bad_request
      assert_match "The user denied", response.body
      assert_not XOauthPendingFlow.exists?(flow.id)
      assert_equal 0, XOauthCredential.count
    end

    test "a token endpoint refusal shows the error and stores nothing" do
      use_hosted_callback!
      flow = start_flow

      with_token_endpoint(code: 400, body: { error: "invalid_request" }) do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code")
      end

      assert_response :bad_request
      assert_match "HTTP 400", response.body
      assert_equal 0, XOauthCredential.count
      assert_not XOauthPendingFlow.exists?(flow.id)
    end

    test "a network failure on the exchange shows the error instead of a 500" do
      use_hosted_callback!
      flow = start_flow

      XOauthCredential.stub(:post_token_request, ->(**) { raise Net::OpenTimeout, "execution expired" }) do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code")
      end

      assert_response :bad_request
      assert_match "Net::OpenTimeout", response.body
      assert_equal 0, XOauthCredential.count
    end

    test "tokens X issued but Zimmer could not save are reported as that, not as a failed exchange" do
      use_hosted_callback!
      flow = start_flow
      XOauthCredential.any_instance.stubs(:apply_token_response!).raises(ActiveRecord::RecordInvalid.new(XOauthCredential.new))

      with_token_endpoint(code: 200, body: TOKEN_BODY) do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code")
      end

      assert_response :bad_request
      assert_match "X issued tokens, but Zimmer could not save them", response.body
    end

    # Administrate's flash partial renders the notice with html_safe, and the
    # account key in it is operator-typed.
    test "the success notice shows the account key as text, not markup" do
      use_hosted_callback!
      flow = start_flow(account_key: "<b>bold</b>")

      with_token_endpoint(code: 200, body: TOKEN_BODY) do
        get supervisor_x_oauth_callback_path(state: flow.state, code: "the-code")
      end
      # follow_redirect! would bypass AutoBasicAuth, so fetch the redirect directly.
      get response.location
      assert_response :success

      assert_select ".flash b", count: 0
      assert_match "&lt;b&gt;bold&lt;/b&gt;", response.body
    end

    test "the authorization code and a pasted redirect URL are filtered from logs" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter(
        "code" => "the-code", "state" => "s", "status_code" => "200",
        "redirect_response" => "http://localhost:8080/callback?state=s&code=the-code"
      )

      assert_equal "[FILTERED]", filtered["code"]
      assert_equal "[FILTERED]", filtered["redirect_response"]
      assert_equal "200", filtered["status_code"]
    end

    # --- the paste-back ---

    test "complete finishes a flow from the pasted redirect URL" do
      ENV.delete(XOauthBootstrap::REDIRECT_URI_ENV)
      flow = start_flow

      _result, request = with_token_endpoint(code: 200, body: TOKEN_BODY) do
        post supervisor_x_oauth_complete_path, params: {
          flow_state: flow.state,
          redirect_response: "http://localhost:8080/callback?state=#{flow.state}&code=pasted-code"
        }
      end

      credential = XOauthCredential.sole
      assert_redirected_to supervisor_x_oauth_credential_path(credential)
      form = URI.decode_www_form(request.body).to_h
      assert_equal "pasted-code", form["code"]
      assert_equal flow.code_verifier, form["code_verifier"]
      assert_equal "http://localhost:8080/callback", form["redirect_uri"]
    end

    test "complete refuses a pasted URL whose state is not a live flow" do
      ENV.delete(XOauthBootstrap::REDIRECT_URI_ENV)
      flow = start_flow

      refute_token_request do
        post supervisor_x_oauth_complete_path, params: {
          flow_state: flow.state,
          redirect_response: "http://localhost:8080/callback?state=someone-elses&code=pasted-code"
        }
      end

      assert_response :bad_request
      assert XOauthPendingFlow.exists?(flow.id)
      assert_equal 0, XOauthCredential.count
    end

    test "complete re-shows the form, flow intact, when the paste carries no state" do
      ENV.delete(XOauthBootstrap::REDIRECT_URI_ENV)
      flow = start_flow

      refute_token_request do
        post supervisor_x_oauth_complete_path, params: { flow_state: flow.state, redirect_response: "pasted-code" }
      end

      assert_response :unprocessable_entity
      assert_select "input[name=flow_state][value=?]", flow.state
      assert XOauthPendingFlow.exists?(flow.id)
      assert_equal 0, XOauthCredential.count
    end

    test "complete with an unusable paste and a gone flow says to start again" do
      refute_token_request do
        post supervisor_x_oauth_complete_path, params: { flow_state: "gone", redirect_response: "pasted-code" }
      end

      assert_response :bad_request
      assert_match "Start again", response.body
    end

    # --- the entry points on the credential pages ---

    test "the credential page offers re-authorization for its own identity" do
      credential = XOauthCredential.create!(account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN")

      get supervisor_x_oauth_credential_path(credential)

      assert_response :success
      assert_select "form[action=?]", supervisor_x_oauth_authorization_path do
        assert_select "input[name=account_key][value=tadasayy]"
        assert_select "input[name=access_token_env_var][value=X_OAUTH_ACCESS_TOKEN]"
        assert_select "button", text: "Re-authorize with X"
      end
    end

    test "the credentials index links to connecting a new account" do
      get supervisor_x_oauth_credentials_path

      assert_response :success
      assert_select "a[href=?]", supervisor_new_x_oauth_authorization_path, text: "Connect an X account"
    end
  end
end
