require "test_helper"
require "mocha/minitest"

# A partial broadcast over a Turbo Stream is rendered with no user and no session,
# so its forms carry no CSRF token. A real submit of one, with forgery protection
# on, is what reached the 422 page on `update_carplay_fit`. The browser half, which
# supplies the page's token, is pinned in test/system/broadcast_rendered_form_csrf_test.rb.
# This half pins what that fix stands on, and that the server still refuses.
class BroadcastRenderedFormCsrfTest < ActionDispatch::IntegrationTest
  # The test environment disables forgery protection, and with it off every request
  # below would succeed and prove nothing.
  setup do
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)

    @session = Session.create!(agent_runtime: "claude_code", status: :needs_input, prompt: "p", title: "t",
      mcp_servers: [], config: {}, git_root: "https://github.com/test/repo.git", branch: "main")
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
  end

  def carplay_form(html)
    Nokogiri::HTML5.fragment(html).at_css(%(form[action="#{update_carplay_fit_session_path(@session)}"])).tap do |form|
      assert form, "the CarPlay fit form should be in this render"
    end
  end

  def broadcast_html
    SessionsController.render(partial: "sessions/session_header_actions", locals: { agent_session: @session })
  end

  def page_token
    get session_path(@session)
    assert_response :success
    css_select('meta[name="csrf-token"]').first["content"]
  end

  test "a broadcast render of the header actions has no token to submit" do
    assert_nil carplay_form(broadcast_html).at_css("input[name=authenticity_token]")
  end

  test "submitting a broadcast-rendered form as it stands is refused and writes nothing" do
    get session_path(@session)

    patch update_carplay_fit_session_path(@session), params: { carplay_fit: "laptop_only" }

    assert_response :unprocessable_entity
    assert_nil @session.reload.carplay_fit
  end

  test "the page's token in the form body is accepted, which is what the browser adds" do
    token = page_token

    patch update_carplay_fit_session_path(@session), params: { carplay_fit: "laptop_only", authenticity_token: token }

    assert_response :redirect
    assert_equal "laptop_only", @session.reload.carplay_fit
    assert_equal "human", @session.carplay_fit_source
  end

  test "the page's token as a header is accepted, which is what the car icon toggle sends" do
    token = page_token

    patch update_carplay_fit_session_path(@session), params: { carplay_fit: "carplay_ok" },
      headers: { "X-CSRF-Token" => token }

    assert_response :redirect
    assert_equal "carplay_ok", @session.reload.carplay_fit
  end

  test "a request render keeps its own per-form token" do
    get session_path(@session)

    assert carplay_form(response.body).at_css("input[name=authenticity_token]")&.[]("value").present?
  end

  test "a token from another session is still refused" do
    token = page_token
    reset!
    get session_path(@session)

    patch update_carplay_fit_session_path(@session), params: { carplay_fit: "laptop_only", authenticity_token: token }

    assert_response :unprocessable_entity
    assert_nil @session.reload.carplay_fit
  end
end
