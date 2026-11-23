require "application_system_test_case"

# Restore a trashed session from its own page and the follow-up composer is there
# straight away, the same as on any other session waiting on its human. The trashed
# page keeps an empty element under the composer's id for exactly this: without it,
# neither the Restore reply nor the status broadcast has anywhere to put the composer.
#
# Run with forgery protection on, as production does, because Restore is a
# turbo_method link that posts with the page's token.
class UnarchiveComposerTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  setup do
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    # Never ran, so UnarchiveSessionService has no clone or transcript to restore
    # and the test exercises the page, not the filesystem.
    @session = Session.create!(
      prompt: "Investigate the flaky test",
      title: "Restored from the trash",
      status: :archived,
      archived_at: 1.hour.ago,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
  end

  test "Restore on the session page shows the follow-up composer without a reload" do
    visit session_path(@session)

    assert_link "Restore"
    assert_no_selector "textarea[name='follow_up_prompt']"
    capture("archived")

    # Survives only if the page is never reloaded or re-visited.
    page.execute_script("window.__noReloadMarker = true")

    click_link "Restore"

    assert_selector "#flash", text: "Session restored from trash."
    assert_selector "textarea[name='follow_up_prompt']", visible: true
    assert_button "Send Message"
    assert_no_link "Restore"
    assert page.evaluate_script("window.__noReloadMarker === true"), "the page reloaded to show the composer"
    assert_equal "needs_input", @session.reload.status
    capture("restored")
  end

  private

  def capture(name)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-unarchive-composer-#{name}.png"))
  end
end
