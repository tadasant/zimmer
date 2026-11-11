require "application_system_test_case"

# Session #27239: Tadas pressed Accept on a 1Password write and the server was
# told "declined". The server asks with a one-field form, a required boolean
# `confirm`, and the banner drew that field as an unticked "Yes" box. Accept sent
# `{"confirm": false}`, and an accept carrying an explicit false is a refusal.
#
# A required yes/no field is the question Accept answers, so Accept now waits
# until it is ticked. Pressing it can no longer record a decline.
class ElicitationBannerAcceptTest < ApplicationSystemTestCase
  # The schema the 1Password MCP server sends, from
  # @pulsemcp/mcp-elicitation's createConfirmationSchema.
  CONFIRMATION_SCHEMA = {
    "type" => "object",
    "properties" => {
      "confirm" => {
        "type" => "boolean",
        "title" => "Create this secure note?",
        "description" => "Confirm that you want to create these secure notes in 1Password."
      }
    },
    "required" => [ "confirm" ]
  }.freeze

  setup do
    # Tall enough that the banner is never under the session page's sticky header
    # when Selenium scrolls a control into view.
    page.driver.browser.manage.window.resize_to(1400, 1800)
    @session = Session.create!(
      title: "Save Aetna ID cards",
      prompt: "Save the cards",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  def create_elicitation(schema)
    Elicitation.create!(
      session: @session,
      request_id: "req-#{SecureRandom.hex(6)}",
      mode: "form",
      message: "Create 1 secure note in vault Zimmer?",
      requested_schema: schema,
      tool_name: "onepassword_create_secure_note",
      expires_at: 1.hour.from_now
    )
  end

  test "Accept waits for the required Yes, then sends confirm: true" do
    elicitation = create_elicitation(CONFIRMATION_SCHEMA)
    visit session_path(@session)

    within("#elicitation_#{elicitation.id}") do
      assert_button "Accept", disabled: true
      assert_text "Tick Yes to accept, or press Decline."

      check "Create this secure note?"
      assert_button "Accept", disabled: false
      assert_no_text "Tick Yes to accept"
      click_button "Accept"
    end

    assert_no_selector "#elicitation_#{elicitation.id}"
    elicitation.reload
    assert_equal "accept", elicitation.status
    assert_equal({ "confirm" => true }, elicitation.response_content)
  end

  test "unticking the required Yes turns Accept off again" do
    elicitation = create_elicitation(CONFIRMATION_SCHEMA)
    visit session_path(@session)

    within("#elicitation_#{elicitation.id}") do
      check "Create this secure note?"
      assert_button "Accept", disabled: false
      uncheck "Create this secure note?"
      assert_button "Accept", disabled: true
    end
    assert elicitation.reload.pending?
  end

  test "Decline still answers no without touching the box" do
    elicitation = create_elicitation(CONFIRMATION_SCHEMA)
    visit session_path(@session)

    within("#elicitation_#{elicitation.id}") { click_button "Decline" }

    assert_no_selector "#elicitation_#{elicitation.id}"
    assert_equal "decline", elicitation.reload.status
  end

  test "an optional yes/no does not hold Accept back" do
    schema = {
      "type" => "object",
      "properties" => { "notify" => { "type" => "boolean", "title" => "Also notify the team?" } }
    }
    elicitation = create_elicitation(schema)
    visit session_path(@session)

    within("#elicitation_#{elicitation.id}") do
      assert_no_text "Tick Yes to accept"
      click_button "Accept"
    end

    assert_no_selector "#elicitation_#{elicitation.id}"
    elicitation.reload
    assert_equal "accept", elicitation.status
    assert_equal({ "notify" => false }, elicitation.response_content)
  end
end
