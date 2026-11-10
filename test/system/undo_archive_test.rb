require "application_system_test_case"

# Trash a session from the board, click the toast's Undo, and the session is back
# where it was — on the board, waiting on its human. Run with forgery protection on,
# as production does, because the Undo button is a form rendered into a stream.
#
# The session has run a turn and logged it, as every real session has: that log
# line is what once sent an undone session to Failed, out of the needs-input queue.
class UndoArchiveTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  setup do
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @session = sessions(:needs_input)
    @session.update_columns(slug: "undo-archive-board-test", title: "Waiting on its human")
    @session.logs.create!(content: "Claude Code CLI completed turn successfully", level: "info")
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
  end

  test "Undo on the User view puts a slug-addressed row back, still needing input" do
    visit root_path(view: SessionsController::VIEW_MODE_USER)
    row = "#user_view_row_#{@session.id}"
    assert_selector row

    within(row) { find("form[action='/sessions/#{@session.slug}/archive'] button").click }

    assert_selector "#flash", text: "Session moved to trash."
    assert_no_selector row
    capture("user-view-trashed")

    within("#flash") { click_on "Undo" }

    assert_selector "#flash", text: "Session restored from trash."
    assert_selector row
    assert_equal "needs_input", @session.reload.status
    assert_nil @session.archived_at
    capture("user-view-undone")
  end

  test "Undo on the card board puts the card back, still needing input" do
    visit root_path(view: SessionsController::VIEW_MODE_LAST_TOUCHED)
    card = "turbo-frame#session_#{@session.id}"
    assert_selector card

    within(card) { click_on "Trash" }

    assert_selector "#flash", text: "Session moved to trash."
    assert_no_selector card
    capture("card-board-trashed")

    within("#flash") { click_on "Undo" }

    assert_selector "#flash", text: "Session restored from trash."
    assert_selector card, text: "Needs Input"
    assert_no_selector card, text: "Failed"
    assert_equal "needs_input", @session.reload.status
    capture("card-board-undone")
  end

  private

  # The toast is fixed to the corner, so scrolling the board to the session's
  # place puts both in one frame.
  def capture(name)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    page.execute_script(<<~JS, @session.id)
      const id = arguments[0]
      const target = document.getElementById(`session_${id}`) || document.getElementById(`user_view_row_${id}`)
      if (target) target.scrollIntoView({ block: "center" })
      else document.querySelector("#sessions_grid, #user_view_list")?.scrollIntoView({ block: "center" })
    JS
    page.save_screenshot(SCREENSHOT_DIR.join("proof-undo-#{name}.png"))
  end
end
