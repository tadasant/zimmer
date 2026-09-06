require "application_system_test_case"

# The four inline catalog editors on the session detail page — MCP servers,
# skills, hooks and plugins — are one Stimulus controller with four sets of
# values (zimmer#456). One implementation is cheaper to keep right than four,
# but only if it is actually exercised as four: each type keys on a different
# catalog field, saves through a different endpoint under a different payload
# key, and MCP alone answers with a turbo-stream rather than JSON.
#
# So this drives every type through the same five steps — type to filter, pick
# with the arrow keys, remove the last chip with backspace, save, and confirm
# the row actually changed in the database. Coverage here used to be a single
# smoke path over the MCP picker.
class CatalogMultiselectTest < ApplicationSystemTestCase
  include MobileOverflowAssertions

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  # accent (which identifies the widget in the DOM), the column it persists to,
  # and how a catalog entry of that type is named.
  def catalogs
    [
      { accent: "indigo", sheet: "mcp-servers", column: :mcp_servers, keys: ServersConfig.all.map(&:name) },
      { accent: "green",  sheet: "skills",      column: :catalog_skills, keys: SkillsConfig.all.map(&:name) },
      { accent: "amber",  sheet: "hooks",       column: :catalog_hooks, keys: HooksConfig.all.map(&:name) },
      { accent: "purple", sheet: "plugins",     column: :catalog_plugins, keys: PluginsConfig.all.map(&:id) }
    ]
  end

  setup do
    @session = Session.create!(
      title: "Catalog multiselect",
      prompt: "Investigate the failure and land a fix.",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  test "typing filters the dropdown for every catalog type" do
    visit session_path(@session)

    catalogs.each do |catalog|
      wanted = catalog[:keys].first
      open_editor(catalog[:accent])
      input = editor_input(catalog[:accent])
      input.click

      assert_selector "#{root(catalog[:accent])} .catalog-multiselect-item", minimum: 1

      input.fill_in with: wanted
      assert_selector "#{root(catalog[:accent])} .catalog-multiselect-item[data-key='#{wanted}']"
      # AND matching across title/description/key means the filter narrows; a
      # nonsense term has to empty the dropdown rather than leave it as it was.
      input.fill_in with: "zzz-no-such-artifact-zzz"
      assert_no_selector "#{root(catalog[:accent])} .catalog-multiselect-item"

      close_editor(catalog[:accent], input)
    end
  end

  test "arrow keys pick an item and backspace removes the last chip" do
    visit session_path(@session)

    catalogs.each do |catalog|
      open_editor(catalog[:accent])
      input = editor_input(catalog[:accent])
      input.click
      assert_selector "#{root(catalog[:accent])} .catalog-multiselect-item", minimum: 1

      # The first row is pre-highlighted, so one ArrowDown lands on the second —
      # except in a catalog with a single entry, where it is a no-op by design.
      rows = page.all("#{root(catalog[:accent])} .catalog-multiselect-item").map { |row| row["data-key"] }
      expected = rows[[ 1, rows.length - 1 ].min]
      input.send_keys(:arrow_down, :enter)

      assert_selector "#{chips(catalog[:accent])} button[data-key='#{expected}']"

      # Backspace on an empty input drops the most recently added chip.
      input.send_keys(:backspace)
      assert_no_selector "#{chips(catalog[:accent])} button[data-key='#{expected}']"

      close_editor(catalog[:accent], input)
    end
  end

  test "saving persists the selection through each type's own endpoint" do
    catalogs.each do |catalog|
      wanted = catalog[:keys].first
      # A fresh load per type: a save can trigger a turbo-stream replacement of
      # the whole meta row, and asserting across that from a stale handle is a
      # race the test does not exist to exercise.
      visit session_path(@session)
      open_editor(catalog[:accent])
      input = editor_input(catalog[:accent])
      input.click
      input.fill_in with: wanted
      find("#{root(catalog[:accent])} .catalog-multiselect-item[data-key='#{wanted}']").click

      assert_selector "#{chips(catalog[:accent])} span", minimum: 1
      # Picking re-opens the dropdown over the button row, exactly as it does for
      # a person; Escape is how both of us get to Save.
      dismiss_dropdown(catalog[:accent], input)
      find("#{root(catalog[:accent])} [data-catalog-multiselect-target='saveButton']", match: :first).click

      # The editor closes on success — MCP by turbo-stream replacement of the
      # whole region, the other three by swapping back to display mode.
      assert_selector "#{root(catalog[:accent])} [data-catalog-multiselect-target='display']:not(.hidden)"

      @session.reload
      assert_equal [ wanted ], @session.public_send(catalog[:column]),
        "expected #{catalog[:column]} to persist #{wanted.inspect}"
    end

    # All four saved: the meta row now carries a chip per type, each in its own
    # accent. Kept as PR evidence that the static class table survived Tailwind.
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.save_screenshot(Rails.root.join("tmp/screenshots/catalog-multiselect-saved-desktop.png").to_s)
  end

  # The chips the server renders behind the editor have to follow a save, or the
  # page shows the old selection until someone reloads it.
  test "a save updates the read-only chips without a reload" do
    skill = SkillsConfig.all.map(&:name).first
    visit session_path(@session)

    open_editor("green")
    input = editor_input("green")
    input.click
    input.fill_in with: skill
    find("#{root("green")} .catalog-multiselect-item[data-key='#{skill}']").click
    dismiss_dropdown("green", input)
    find("#{root("green")} [data-catalog-multiselect-target='saveButton']", match: :first).click

    assert_selector "#{root("green")} [data-role='catalog-selected'] [data-chip]", text: skill
  end

  # The dropdown is `position: fixed`, so it contributes nothing to the document's
  # scroll width and Probe 1 cannot see it at all. Three of the four pickers also
  # changed formula here — they used to size against `window.innerWidth - 32`,
  # which counts an in-flow scrollbar the layout cannot use, and that 15px is what
  # put the old MCP dropdown 23px off the right edge of a phone. So the open
  # dropdown is measured directly, per type, at 375px.
  test "every picker's open dropdown fits a 375px phone" do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
    visit session_path(@session)

    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))

    catalogs.each do |catalog|
      # The phone's copy of each editor lives in the joystick's bottom sheet, and
      # the desktop meta row is not rendered at this width at all.
      reveal_mobile_sheet(catalog[:sheet])
      open_editor(catalog[:accent])
      editor_input(catalog[:accent]).click
      assert_selector "#{root(catalog[:accent])} .catalog-multiselect-item", minimum: 1

      assert_empty past_right_edge(root(catalog[:accent])),
        "#{catalog[:accent]} picker sticks out at #{MOBILE_WIDTH}px"
      assert_no_horizontal_overflow("session page with the #{catalog[:accent]} picker open")

      page.save_screenshot(Rails.root.join("tmp/screenshots/catalog-multiselect-#{catalog[:accent]}-375.png").to_s)

      # The sheets are independent overlays, so hiding this one takes its open
      # dropdown with it — no need to walk the editor back to display mode.
      hide_mobile_sheet(catalog[:sheet])
    end
  end

  private

  def reveal_mobile_sheet(kind)
    page.execute_script(%(document.querySelector("[data-modal-kind='#{kind}']")?.classList.remove("hidden")))
    assert_selector "[data-modal-kind='#{kind}']"
  end

  def hide_mobile_sheet(kind)
    page.execute_script(%(document.querySelector("[data-modal-kind='#{kind}']")?.classList.add("hidden")))
    assert_no_selector "[data-modal-kind='#{kind}']"
  end

  # The mobile-QA skill's Probe 2, scoped to one widget: every element inside it
  # whose right edge is past the viewport. `getBoundingClientRect` sees straight
  # through both a clipping ancestor and `position: fixed`, which is the point —
  # the dropdown is fixed, so the document's scroll width never reflects it.
  #
  # Scoped rather than run over the whole document because Zimmer parks two panels
  # off-canvas on purpose (the notes drawer and the chat popover, both
  # `translate-x-full`), and an unscoped probe reports those on every page. The
  # page-level gate is `assert_no_horizontal_overflow`, which knows to ignore them.
  def past_right_edge(scope)
    page.evaluate_script(<<~JS)
      (function () {
        const limit = document.documentElement.clientWidth;
        const roots = Array.from(document.querySelectorAll(#{scope.to_json}));
        return roots
          .flatMap((root) => Array.from(root.querySelectorAll("*")))
          .filter((el) => el.getBoundingClientRect().width > 0)
          .filter((el) => el.getBoundingClientRect().right > limit + 1)
          .slice(0, 20)
          .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value} @ ${Math.round(el.getBoundingClientRect().right)}px`);
      })()
    JS
  end

  def root(accent)
    "[data-controller='catalog-multiselect'][data-catalog-multiselect-accent-value='#{accent}']"
  end

  def chips(accent)
    "#{root(accent)} [data-catalog-multiselect-target='selectedContainer']"
  end

  def editor_input(accent)
    find("#{root(accent)} [data-catalog-multiselect-target='input']", match: :first)
  end

  # Escape only when there is a dropdown to close: the second Escape would leave
  # the editor, and a catalog with one entry hides the list on its own once that
  # entry is picked.
  def dismiss_dropdown(accent, input)
    return unless has_selector?("#{root(accent)} .catalog-multiselect-item", wait: 0)

    input.send_keys(:escape)
    assert_no_selector "#{root(accent)} .catalog-multiselect-item"
  end

  # Escape is two steps by design: the first closes an open dropdown, the second
  # leaves the editor — so how many it takes depends on whether the dropdown was
  # showing. An editor left open would sit over the next widget's Edit button,
  # because the dropdown is position:fixed.
  def close_editor(accent, input)
    input.send_keys(:escape)
    input.send_keys(:escape) if has_selector?("#{root(accent)} [data-catalog-multiselect-target='editor']:not(.hidden)")
    assert_selector "#{root(accent)} [data-catalog-multiselect-target='display']:not(.hidden)"
  end

  # Click the widget's own Edit affordance rather than toggling classes, so the
  # controller's `edit()` runs and the test covers the real entry point. The
  # desktop copy is the first match; the mobile sheet carries a second.
  #
  # Scrolled to the middle of the viewport first: the session page has a sticky
  # follow-up form, and a 14px icon near the bottom of the fold lands under it.
  def open_editor(accent)
    button = find("#{root(accent)} [data-action~='click->catalog-multiselect#edit']", match: :first)
    page.scroll_to(button, align: :center)
    button.click
    assert_selector "#{root(accent)} [data-catalog-multiselect-target='editor']:not(.hidden)"
  end
end
