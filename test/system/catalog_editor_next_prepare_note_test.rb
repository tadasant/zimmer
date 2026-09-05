require "application_system_test_case"

# Changing a session's MCP servers, skills, hooks or plugins persists the list and
# stops there: the change lands on the session's next prepare, not on the process
# already running. That is invisible unless the editor says so, and a user who is
# not told will read a saved change as an applied one.
#
# So each of the four editors carries the note, and each one still fits a phone
# with it — the desktop editors put it on its own line via `flex-wrap` + `basis-full`,
# which is the shape that goes wrong if the wrap is dropped later.
class CatalogEditorNextPrepareNoteTest < ApplicationSystemTestCase
  include MobileOverflowAssertions

  # One per editor: the Stimulus controller identifier, and the noun the note ends on.
  EDITORS = [
    [ "editable-mcp-servers", "servers" ],
    [ "editable-catalog-skills", "skills" ],
    [ "editable-catalog-hooks", "hooks" ],
    [ "editable-catalog-plugins", "plugins" ]
  ].freeze

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "every catalog editor says the change lands on the next prepare, and fits a phone" do
    session = Session.create!(
      title: "Catalog editor note",
      prompt: "Investigate the failure and land a fix.",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "feature/a-fairly-long-branch-name-for-overflow-testing"
    )

    page.driver.browser.manage.window.resize_to(1400, 900)
    visit session_path(session)

    EDITORS.each do |controller, noun|
      open_editor(controller)
      assert_selector "[data-controller='#{controller}'] [data-#{controller}-target='editor']",
        text: "Applies on the next turn or restart — the running process keeps its current #{noun}."
    end

    save_evidence("catalog-editors-desktop")

    # The four notes are open together, which is the widest the section ever gets.
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
    EDITORS.each { |controller, _| open_editor(controller) }

    assert_no_horizontal_overflow("session page with every catalog editor open")

    save_evidence("catalog-editors-375")

    # The phone's own copy of the editors lives in the joystick's bottom sheets,
    # which carry the note as a block line rather than a wrapped flex child.
    reveal_mobile_sheet("mcp-servers")
    assert_selector "[data-modal-kind='mcp-servers']",
      text: "Applies on the next turn or restart — the running process keeps its current servers."
    assert_no_horizontal_overflow("mobile MCP servers sheet")
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.save_screenshot(Rails.root.join("tmp/screenshots/catalog-editor-mobile-sheet-375.png").to_s)
  end

  private

  def reveal_mobile_sheet(kind)
    page.execute_script(<<~JS)
      const sheet = document.querySelector("[data-modal-kind='#{kind}']");
      if (sheet) sheet.classList.remove("hidden");
    JS
  end

  def save_evidence(name)
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.execute_script(<<~JS)
      const editor = document.querySelector("[data-editable-mcp-servers-target='editor']:not(.hidden)");
      if (editor) editor.scrollIntoView({ block: "center" });
    JS
    page.save_screenshot(Rails.root.join("tmp/screenshots/#{name}.png").to_s)
  end

  # The editors reveal themselves by toggling `hidden` on their two targets. Drive
  # that directly rather than hunting the pencil button, which is a 14px icon whose
  # position depends on how long the current selection renders.
  def open_editor(controller)
    page.execute_script(<<~JS)
      document.querySelectorAll("[data-controller='#{controller}']").forEach((root) => {
        const display = root.querySelector("[data-#{controller}-target='display']");
        const editor = root.querySelector("[data-#{controller}-target='editor']");
        if (display) display.classList.add("hidden");
        if (editor) editor.classList.remove("hidden");
      });
    JS
  end
end
