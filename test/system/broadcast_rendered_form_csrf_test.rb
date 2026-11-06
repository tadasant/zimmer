require "application_system_test_case"

# A broadcast replaces a form with a render that has no session, so the chevron
# menu's `data-turbo="false"` form has no token of its own and the page has to supply
# it. Only a real browser with forgery protection on can show this: the test
# environment disables it, and a request test cannot run the page's JavaScript.
#
# The test cable adapter delivers nothing to the browser, so each test hands the page
# the same stream a broadcast would, built from the same render the model uses.
class BroadcastRenderedFormCsrfSystemTest < ApplicationSystemTestCase
  setup do
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    @session = Session.create!(agent_runtime: "claude_code", status: :needs_input, prompt: "p",
      title: "Waiting on a car", mcp_servers: [], config: {},
      git_root: "https://github.com/test/repo.git", branch: "main")
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
  end

  def deliver_broadcast(target, html)
    stream = %(<turbo-stream action="replace" target="#{target}"><template>#{html}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(arguments[0])", stream)
  end

  def broadcast_header_actions
    deliver_broadcast("session_#{@session.id}_header_actions",
      SessionsController.render(partial: "sessions/session_header_actions", locals: { agent_session: @session }))
    assert_no_selector "#{header} form[action$='update_carplay_fit'] input[name='authenticity_token']", visible: :all
  end

  def header
    "#session_#{@session.id}_header_actions"
  end

  def choose_laptop_only
    find("#{header} summary[aria-label='More CarPlay fit choices']").click
    find("#{header} button[value='laptop_only']").click
  end

  def assert_mark_written
    assert_text "marked Laptop only"
    assert_equal "laptop_only", @session.reload.carplay_fit
    assert_equal "human", @session.carplay_fit_source
  end

  test "the chevron menu works in the dashboard drawer after a broadcast replaced it" do
    visit root_path
    find("a[href='#{session_path(@session)}'][data-action*='session-drawer#open']").click
    assert_selector "#{header} form[action$='update_carplay_fit'] input[name='authenticity_token']", visible: :all

    broadcast_header_actions
    choose_laptop_only

    assert_mark_written
  end

  test "the chevron menu works on the detail page after a broadcast replaced it" do
    visit session_path(@session)
    assert_selector header

    broadcast_header_actions
    choose_laptop_only

    assert_mark_written
  end

  test "the car icon toggle works after a broadcast replaced it" do
    visit session_path(@session)
    assert_selector header

    broadcast_header_actions
    find("#{header} [data-carplay-fit-toggle] a").click

    assert_selector "#{header} [data-carplay-fit-toggle='on']"
    assert_equal "carplay_ok", @session.reload.carplay_fit
  end

  test "another non-Turbo form in a broadcast partial works after a broadcast replaced it" do
    visit session_path(@session)
    assert_selector "#session-precedence"

    deliver_broadcast("session_#{@session.id}_metadata",
      SessionsController.render(partial: "sessions/session_metadata", locals: @session.send(:metadata_broadcast_locals)))
    assert_no_selector "#session-precedence input[name='authenticity_token']", visible: :all

    within("#session-precedence") do
      fill_in "precedence", with: "7"
      click_button "Set"
    end

    assert_text "Precedence is now 7."
    assert_equal 7, @session.reload.precedence
  end

  test "only a same-origin POST without a token gets one" do
    visit session_path(@session)
    assert_selector header

    result = page.evaluate_script(<<~JS)
      (function () {
        const page = document.querySelector("meta[name='csrf-token']").content;
        const read = ({ action = "/sessions", method = "post", field, button = {} }) => {
          const form = document.createElement("form");
          form.dataset.turbo = "false";
          form.setAttribute("method", method);
          form.setAttribute("action", action);
          form.addEventListener("submit", (event) => event.preventDefault());
          if (field) {
            const input = document.createElement("input");
            input.name = "authenticity_token";
            input.value = field;
            form.append(input);
          }
          const submitter = document.createElement("button");
          Object.entries(button).forEach(([name, value]) => submitter.setAttribute(name, value));
          form.append(submitter);
          document.body.append(form);
          form.requestSubmit(submitter);
          const token = new FormData(form).get("authenticity_token");
          form.remove();
          return token;
        };
        return {
          filled: read({}) === page,
          kept: read({ field: "per-form" }),
          crossOrigin: read({ action: "https://example.com/collect" }),
          get: read({ method: "get" }),
          submitterCrossOrigin: read({ button: { formaction: "https://example.com/collect" } }),
          submitterGet: read({ button: { formmethod: "get" } })
        };
      })()
    JS

    assert_equal({ "crossOrigin" => nil, "filled" => true, "get" => nil, "kept" => "per-form",
                   "submitterCrossOrigin" => nil, "submitterGet" => nil }, result)
  end
end
