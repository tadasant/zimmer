require "application_system_test_case"
require "mocha/minitest"

# The OAuth consent screen at a phone's width. Its first reader is a phone: Zimmer's
# iOS app opens /oauth/authorize in the system sign-in sheet, so "Approve" has to
# be on screen at 375px. The page carries unbreakable strings — the /mcp resource
# URL, the signed-in email, the redirect scheme — which is the shape that runs off
# the right edge.
class OauthConsentMobileTest < ApplicationSystemTestCase
  include WebAuthTestHelpers

  MOBILE_WIDTH = 375
  MOBILE_HEIGHT = 812
  ENV_KEYS = %w[OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS ZIMMER_DEV_WEB_USER_EMAIL].freeze

  NO_DOCUMENT_OVERFLOW = <<~JS
    document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1
  JS

  # getBoundingClientRect sees through a clipping ancestor and through
  # `position: fixed`, both of which Probe 1 is blind to.
  ELEMENTS_PAST_RIGHT_EDGE = <<~JS
    (function () {
      const limit = document.documentElement.clientWidth;
      return Array.from(document.querySelectorAll("main *"))
        .filter((el) => el.getBoundingClientRect().right > limit + 1)
        .slice(0, 20)
        .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value} @ ${Math.round(el.getBoundingClientRect().right)}px`);
    })()
  JS

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["OAUTH_SERVER_ISSUER"] = "https://zimmer-with-a-long-hostname.example-deployment.test"
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "someone-with-a-long-address@tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "the consent screen for the built-in iOS app fits a phone, with Approve on screen" do
    verifier = SecureRandom.urlsafe_base64(48)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    visit "/oauth/authorize?" + {
      response_type: "code", client_id: OauthServer::NativeApp::CLIENT_ID,
      redirect_uri: OauthServer::NativeApp::REDIRECT_URI, code_challenge: challenge,
      code_challenge_method: "S256", state: "x" * 43,
      resource: "#{ENV['OAUTH_SERVER_ISSUER']}/mcp"
    }.to_query

    assert_text "Connect Zimmer for iOS to Zimmer?"
    assert_text "com.tadasant.zimmer:"
    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW), "the consent screen is wider than a 375px phone"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE)

    approve = find_button("Approve")
    right = page.evaluate_script("arguments[0].getBoundingClientRect().right", approve.native)
    assert_operator right, :<=, page.evaluate_script("document.documentElement.clientWidth")

    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.save_screenshot(Rails.root.join("tmp/screenshots/oauth-consent-ios-375.png").to_s)
  end
end
