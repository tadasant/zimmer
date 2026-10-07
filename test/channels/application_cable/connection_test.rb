# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The cable's half of the web login wall: every Turbo Stream arrives over this
# one WebSocket, so with the gate on a browser without a sign-in cookie is
# refused at connect.
class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  include WebAuthTestHelpers

  def signed_in_identity
    WebIdentity.create!(google_sub: "sub-cable", email: "tadas@tadasant.com", hosted_domain: "tadasant.com",
      totp_secret: WebAuth::Totp.generate_secret, totp_enrolled_at: 1.day.ago)
  end

  test "with the gate off, anyone connects, as before" do
    WebAuth::Configuration.stubs(:current).returns(WebAuth::Configuration.new({}))

    connect
    assert_nil connection.web_identity
  end

  test "with the gate on, a connection without a sign-in cookie is refused" do
    enable_web_auth

    assert_reject_connection { connect }
  end

  test "with the gate on, a signed-in browser connects as its identity" do
    configuration = enable_web_auth
    identity = signed_in_identity
    cookies.encrypted[WebAuth::Cookies::SIGN_IN] = { value: { "id" => identity.id, "g" => identity.session_generation, "f" => "totp", "r" => Time.current.to_i } }

    connect
    assert_equal identity, connection.web_identity
    assert configuration.totp_required?
  end

  test "a sign-in cookie from before a sign-out-everywhere is refused" do
    enable_web_auth
    identity = signed_in_identity
    cookies.encrypted[WebAuth::Cookies::SIGN_IN] = { value: { "id" => identity.id, "g" => identity.session_generation, "f" => "totp", "r" => Time.current.to_i } }
    identity.sign_out_everywhere!

    assert_reject_connection { connect }
  end

  test "a store that has never answered refuses rather than guesses" do
    WebAuth::Configuration.stubs(:current).raises(WebAuth::Configuration::Unavailable, "down")

    assert_reject_connection { connect }
  end
end
