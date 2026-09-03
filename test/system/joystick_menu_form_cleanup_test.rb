require "application_system_test_case"

# The mobile joystick's menu actions submit through a <form> the controller
# builds, appends to document.body and hands to Turbo. Turbo answers those
# actions with a turbo_stream, which is the point — the page updates in place
# instead of reloading — and is also what leaves the form behind: a native
# navigation would tear the document down and take it along, a stream does not.
#
# So the session page has to be able to sit open through any number of menu
# actions without collecting one submittable form per action.
class JoystickMenuFormCleanupTest < ApplicationSystemTestCase
  MOBILE = [ 375, 812 ].freeze
  ACTIONS = 3

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "firing a joystick menu action repeatedly leaves no forms on document.body" do
    session = Session.create!(
      prompt: "Joystick form cleanup",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    page.driver.browser.manage.window.resize_to(*MOBILE)
    visit session_path(session)
    wait_for_stimulus_controller("joystick-menu")

    assert_equal 0, body_form_count, "the page should start with no forms on document.body"
    watch_for_appended_forms

    # Favorite is the repeatable action here: it toggles, and #toggle_favorite
    # answers on its turbo_stream branch, so the document survives each one.
    ACTIONS.times do |i|
      # Reveal the bottom sheet directly rather than driving the press-and-hold
      # gesture: what is under test is the submit path behind the sheet's rows,
      # and the gesture has its own coverage.
      reveal_sheet
      favorited_before = session.reload.favorited?
      row = find("[data-joystick-menu-target='sheet'] button[data-petal-key='favorite']")
      scroll_into_center(row)
      row.click
      assert_eventually("favorite ##{i + 1} should have toggled the session") do
        session.reload.favorited? != favorited_before
      end
      assert_eventually("the form from favorite ##{i + 1} should be removed") { body_form_count.zero? }
    end

    # Both halves matter. Without the second, a refactor that stopped building
    # a form at all — a bare fetch, a server-rendered button_to — would keep
    # this test green while it asserted nothing about cleanup.
    assert_equal 0, body_form_count,
      "document.body should hold no leftover joystick submission forms"
    assert_equal ACTIONS, appended_form_count,
      "each action should still have submitted through a form appended to document.body"
  end

  private

  def reveal_sheet
    assert_selector "[data-joystick-menu-target='sheet']", visible: :all
    page.execute_script(<<~JS)
      const sheet = document.querySelector("[data-joystick-menu-target='sheet']");
      sheet.classList.remove("translate-y-full", "opacity-0");
    JS
  end

  # Count the forms as they are appended, not just the ones left behind — the
  # controller removes them, so by assertion time there is nothing to count.
  def watch_for_appended_forms
    page.execute_script(<<~JS)
      window.__joystickFormsAppended = 0
      new MutationObserver((records) => {
        records.forEach((record) => {
          record.addedNodes.forEach((node) => {
            if (node.nodeName === "FORM") window.__joystickFormsAppended += 1
          })
        })
      }).observe(document.body, { childList: true })
    JS
  end

  def appended_form_count
    page.evaluate_script("window.__joystickFormsAppended")
  end

  # Only the forms the controller parks directly on document.body — the page's
  # own server-rendered forms live inside its layout, not as body children.
  def body_form_count
    page.evaluate_script("document.querySelectorAll('body > form').length")
  end
end
