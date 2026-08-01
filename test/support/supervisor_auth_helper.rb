# frozen_string_literal: true

# The /supervisor Administrate panel sits behind an HTTP Basic realm whose
# credentials come from the environment, and it fails closed when they are
# unset (Supervisor::ApplicationController). Every test that drives a supervisor
# page therefore has to configure the realm and then present a credential.
#
# Include this in the test case to do the first half. The second half depends on
# how the test talks to the app:
#
#   - integration tests also include AutoBasicAuth, which attaches the header to
#     every request, so existing `get supervisor_logs_url` call sites keep working;
#   - system tests drive a real browser, which has no header hook, so they push
#     the same credential in over CDP (see test/system/supervisor_test.rb).
#
# Tests that assert on the gate itself — 401 paths, fail-closed-when-unset — do
# not include this; they manage the environment themselves.
module SupervisorAuthTestHelper
  extend ActiveSupport::Concern

  USERNAME = "supervisor"
  PASSWORD = "test-supervisor-password"

  included do
    setup do
      ENV[Supervisor::ApplicationController::PASSWORD_ENV] = PASSWORD
    end

    teardown do
      ENV.delete(Supervisor::ApplicationController::PASSWORD_ENV)
    end
  end

  def supervisor_basic_credentials
    ActionController::HttpAuthentication::Basic.encode_credentials(USERNAME, PASSWORD)
  end

  def supervisor_auth_headers
    { "HTTP_AUTHORIZATION" => supervisor_basic_credentials }
  end

  # Attaches the Basic header to every request the including integration test
  # makes. Included (not prepended) into the test class, so it sits ahead of
  # ActionDispatch::Integration::Runner in the ancestor chain and `super`
  # reaches Runner's real implementation. An explicit `headers:` at the call
  # site still wins.
  module AutoBasicAuth
    %w[get post patch put delete head].each do |verb|
      define_method(verb) do |path, **args|
        args[:headers] = supervisor_auth_headers.merge(args[:headers] || {})
        super(path, **args)
      end
    end
  end
end
