# frozen_string_literal: true

# Carries the operator HTTP Basic credential (OperatorHttpBasicAuth) for integration tests
# whose subject is the *behaviour* behind the gate rather than the gate itself.
#
# Including it configures the realm for the duration of the test and makes every POST the
# test issues carry a valid credential, so tests written before the `/health` maintenance
# actions were gated keep asserting what they were written to assert.
#
# It deliberately does NOT cover the gate. Nothing here would notice
# `before_action :authenticate_operator` disappearing — that is
# test/controllers/health_controller_operator_auth_test.rb's job, and it asserts both
# directions on every gated route by name.
module OperatorBasicAuthHelpers
  PASSWORD = "operator-test-password"

  def self.included(base)
    base.setup { enable_operator_credential }
    base.teardown { restore_operator_credential }
  end

  def enable_operator_credential
    @original_operator_password = ENV[OperatorHttpBasicAuth::PASSWORD_ENV]
    @original_operator_username = ENV[OperatorHttpBasicAuth::USERNAME_ENV]

    ENV[OperatorHttpBasicAuth::PASSWORD_ENV] = PASSWORD
    # The default username is what operator_headers signs with; an inherited override
    # would make every request in the including test 401.
    ENV.delete(OperatorHttpBasicAuth::USERNAME_ENV)
  end

  def restore_operator_credential
    restore_operator_env(OperatorHttpBasicAuth::PASSWORD_ENV, @original_operator_password)
    restore_operator_env(OperatorHttpBasicAuth::USERNAME_ENV, @original_operator_username)
  end

  def operator_headers(extra = {})
    {
      "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(
        OperatorHttpBasicAuth::DEFAULT_USERNAME, PASSWORD
      )
    }.merge(extra)
  end

  # Only POST is wrapped: the gate is on the mutating actions, and every GET on /health is
  # deliberately still anonymous — wrapping those would hide a gate accidentally spreading
  # to the read-only dashboard.
  def post(path, **args)
    args[:headers] = operator_headers(args[:headers] || {})
    super(path, **args)
  end

  private

  def restore_operator_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
