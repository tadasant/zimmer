require "application_system_test_case"

# The four catalog pickers on the new-session form — MCP servers, skills, hooks
# and plugins — are the same `catalog-multiselect` controller the session detail
# page uses, in its FORM mode: no save endpoint, hidden inputs that submit with
# the form, and a reset to the agent root's defaults when the root changes
# (zimmer#456, second half). Each type is driven through the same steps —
# type to filter, pick with the arrow keys, remove with backspace — and then the
# two things only form mode does: the hidden inputs the server will read, and
# the agent-root reset. The trigger form is covered where it differs: a stored
# name the catalog no longer carries has to survive the round-trip (zimmer#853).
class CatalogMultiselectFormTest < ApplicationSystemTestCase
  include MobileOverflowAssertions

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  # `field` is the wrapper's `data-catalog-field`, `param` the hidden inputs'
  # name, `keys` how a catalog entry of that type is named.
  def catalogs
    [
      { field: "mcp_servers",     column: :mcp_servers,     keys: ServersConfig.all.map(&:name) },
      { field: "catalog_skills",  column: :catalog_skills,  keys: SkillsConfig.all.map(&:name) },
      { field: "catalog_hooks",   column: :catalog_hooks,   keys: HooksConfig.all.map(&:name) },
      { field: "catalog_plugins", column: :catalog_plugins, keys: PluginsConfig.all.map(&:id) }
    ]
  end

  test "typing filters the dropdown for every catalog type" do
    visit new_session_url

    catalogs.each do |catalog|
      wanted = catalog[:keys].first
      input = picker_input(catalog[:field])
      input.click
      assert_selector "#{root(catalog[:field])} .catalog-multiselect-item", minimum: 1

      input.fill_in with: wanted
      assert_selector "#{root(catalog[:field])} .catalog-multiselect-item[data-key='#{wanted}']"
      # AND matching across title/description/key means the filter narrows; a
      # nonsense term has to empty the dropdown rather than leave it as it was.
      input.fill_in with: "zzz-no-such-artifact-zzz"
      assert_no_selector "#{root(catalog[:field])} .catalog-multiselect-item"

      input.fill_in with: ""
      dismiss_dropdown(catalog[:field], input)
    end
  end

  test "arrow keys pick an item, backspace removes it, and the hidden inputs follow" do
    visit new_session_url

    catalogs.each do |catalog|
      input = picker_input(catalog[:field])
      input.click
      assert_selector "#{root(catalog[:field])} .catalog-multiselect-item", minimum: 1

      # The first row is pre-highlighted, so one ArrowDown lands on the second —
      # except in a catalog with a single entry, where it is a no-op by design.
      rows = page.all("#{root(catalog[:field])} .catalog-multiselect-item").map { |row| row["data-key"] }
      expected = rows[[ 1, rows.length - 1 ].min]
      input.send_keys(:arrow_down, :enter)

      assert_selector "#{chips(catalog[:field])} button[data-key='#{expected}']"
      # The chip is what the person sees; the hidden input is what the server
      # gets. Both, or the form lies.
      assert_selector hidden_input(catalog[:column], expected), visible: :all

      # Backspace on an empty input drops the most recently added chip.
      input.send_keys(:backspace)
      assert_no_selector "#{chips(catalog[:field])} button[data-key='#{expected}']"
      assert_no_selector hidden_input(catalog[:column], expected), visible: :all

      dismiss_dropdown(catalog[:field], input)
    end
  end

  # The subtlest behaviour in the widget, and the one PR #1035 could not cover
  # because the inline editors have no agent root to follow. The agent-root
  # control sits outside every picker's element, so the reset travels as a
  # document-level `ao:agent-root-changed` rather than a Stimulus action — the
  # exact wiring a refactor is most likely to drop.
  test "picking an agent root replaces every catalog selection with that root's defaults" do
    root_with_defaults = AgentRootsConfig.user_invocable.find { |r| r.default_mcp_servers.present? && r.default_skills.present? }
    skip "the test catalog has no agent root with default MCP servers and skills" unless root_with_defaults
    bare_root = AgentRootsConfig.user_invocable.find { |r| r.default_mcp_servers.blank? && r.default_skills.blank? && r.default_plugins.blank? }
    skip "the test catalog has no agent root without defaults" unless bare_root

    visit new_session_url
    select_agent_root(bare_root.name)

    # Hand-pick one of each, so the reset has something to replace and not
    # merely something to add.
    catalogs.each do |catalog|
      picked = catalog[:keys].first
      input = picker_input(catalog[:field])
      input.click
      input.fill_in with: picked
      find("#{root(catalog[:field])} .catalog-multiselect-item[data-key='#{picked}']").click
      assert_selector "#{chips(catalog[:field])} button[data-key='#{picked}']"
      dismiss_dropdown(catalog[:field], input)
    end

    select_agent_root(root_with_defaults.name)

    expected = {
      mcp_servers: root_with_defaults.default_mcp_servers.select { |n| ServersConfig.exists?(n) },
      catalog_skills: root_with_defaults.default_skills.select { |n| SkillsConfig.exists?(n) },
      catalog_hooks: root_with_defaults.default_hooks.to_a.select { |n| HooksConfig.exists?(n) },
      catalog_plugins: root_with_defaults.default_plugins.to_a.select { |n| PluginsConfig.exists?(n) }
    }

    catalogs.each do |catalog|
      wanted = expected.fetch(catalog[:column])
      # A waiting assertion before the `wait: 0` comparison, so a slow repaint
      # reads as slow rather than as the wrong selection.
      wanted.each { |key| assert_selector "#{chips(catalog[:field])} button[data-key='#{key}']" }

      assert_equal wanted, chip_keys(catalog[:field]),
        "#{catalog[:field]} should carry exactly #{root_with_defaults.name}'s defaults"
      assert_equal wanted, submitted_values(catalog[:column]),
        "#{catalog[:field]}'s hidden inputs should match its chips"
    end

    # And back to a root with nothing: every picker empties, including the ones
    # whose defaults were just populated.
    select_agent_root(bare_root.name)
    catalogs.each do |catalog|
      assert_empty chip_keys(catalog[:field]), "#{catalog[:field]} should be empty under #{bare_root.name}"
    end

    # Only the MCP picker posts a blank when empty: SessionsController reads
    # the key's presence as "the human deliberately chose none".
    assert_equal [ "" ], submitted_values(:mcp_servers)
    assert_empty submitted_values(:catalog_skills)
  end

  test "the selection arrives on the created session" do
    visit new_session_url
    fill_in "session[prompt]", with: "Exercise every catalog picker at once"

    picked = catalogs.to_h do |catalog|
      key = catalog[:keys].first
      input = picker_input(catalog[:field])
      input.click
      input.fill_in with: key
      find("#{root(catalog[:field])} .catalog-multiselect-item[data-key='#{key}']").click
      assert_selector "#{chips(catalog[:field])} button[data-key='#{key}']"
      dismiss_dropdown(catalog[:field], input)
      [ catalog[:column], key ]
    end

    click_button "Create Session"
    assert_text "Session created successfully"

    session = Session.order(:id).last
    picked.each do |column, key|
      assert_equal [ key ], session.public_send(column), "expected #{column} to arrive as #{key.inspect}"
    end
  end

  # `group_by_category` and `show_description` are the two values that differ
  # per type, which makes them the two most likely to be mis-wired by a
  # parameterisation — and the trigger form wires them a second time. Asserted
  # as a full four-way matrix, both halves of it: a test that only checks the
  # types that DO show a description passes while a type that should silently
  # stops.
  test "category grouping and row descriptions are wired per type, on both forms" do
    matrix = {
      "mcp_servers" => { grouped: false, described: false },
      "catalog_skills" => { grouped: true,  described: false },
      "catalog_hooks" => { grouped: false, described: true },
      "catalog_plugins" => { grouped: false, described: true }
    }

    [ new_session_url, new_trigger_url ].each do |url|
      visit url

      matrix.each do |field, expected|
        input = picker_input(field)
        input.click
        assert_selector "#{root(field)} .catalog-multiselect-item", minimum: 1

        headers = "#{root(field)} [data-role='catalog-category']"
        expected[:grouped] ? assert_selector(headers, minimum: 1) : assert_no_selector(headers)

        rows = "#{root(field)} .catalog-multiselect-item [data-role='catalog-description']"
        expected[:described] ? assert_selector(rows, minimum: 1) : assert_no_selector(rows)

        dismiss_dropdown(field, input)
      end
    end
  end

  # zimmer#853: a trigger's stored column may name an artifact the catalog no
  # longer carries. The form has to show it and post it back, or an edit to any
  # other field silently deletes the very name the alert told the operator to
  # remap. Stored via update_column because the model refuses a fresh write of
  # an unknown name — which is the point: it was valid when it was stored.
  test "the trigger form keeps and marks a stored name the catalog no longer carries" do
    trigger = create_trigger
    trigger.update_columns(catalog_skills: [ "ghost-skill" ], mcp_servers: [ "ghost-server" ])

    visit edit_trigger_url(trigger)

    assert_selector "#{chips("catalog_skills")} span", text: "ghost-skill (not in catalog)"
    assert_selector "#{chips("mcp_servers")} span", text: "ghost-server (not in catalog)"
    assert_equal [ "ghost-skill" ], submitted_values(:catalog_skills, scope: "trigger")
    assert_equal [ "ghost-server" ], submitted_values(:mcp_servers, scope: "trigger")
  end

  test "the trigger form's pickers reset to the chosen root's defaults" do
    root_with_defaults = AgentRootsConfig.all.find { |r| r.default_mcp_servers.present? }
    skip "the test catalog has no agent root with default MCP servers" unless root_with_defaults

    trigger = create_trigger
    visit edit_trigger_url(trigger)

    # Wait for the widget to exist before reading a `wait: 0` emptiness off it —
    # otherwise "no chips" is indistinguishable from "not connected yet".
    assert_selector "#{root("mcp_servers")} [data-catalog-multiselect-target='input']"
    assert_empty chip_keys("mcp_servers")

    # The trigger form's agent root is a plain <select>; trigger-form re-broadcasts
    # its change as the document event the pickers listen for.
    select root_with_defaults.display_name, from: "trigger[agent_root_name]"

    expected = root_with_defaults.default_mcp_servers.select { |n| ServersConfig.exists?(n) }
    expected.each { |key| assert_selector "#{chips("mcp_servers")} button[data-key='#{key}']" }

    assert_equal expected, chip_keys("mcp_servers")
    assert_equal expected, submitted_values(:mcp_servers, scope: "trigger")
  end

  # The typeahead behind "/" in the prompt is derived from the skills picker's
  # selection, announced as `catalog-multiselect:selectionChanged`. All four
  # pickers announce through that one event, so this is also the check that the
  # listener keys on the right one.
  test "the slash-command typeahead follows the skills selection" do
    skill = SkillsConfig.all.find(&:user_invocable)
    skip "the test catalog has no user-invocable skill" unless skill

    visit new_session_url
    input = picker_input("catalog_skills")
    input.click
    input.fill_in with: skill.name
    find("#{root("catalog_skills")} .catalog-multiselect-item[data-key='#{skill.name}']").click
    dismiss_dropdown("catalog_skills", input)

    fill_in "session[prompt]", with: "/"
    assert_selector "[data-slash-command-target='dropdown']:not(.hidden)", text: skill.name

    # Removing the skill takes it out of the typeahead again.
    find("#{chips("catalog_skills")} button[data-key='#{skill.name}']").click
    fill_in "session[prompt]", with: ""
    fill_in "session[prompt]", with: "/"
    assert_no_selector "[data-slash-command-target='dropdown']:not(.hidden)", text: skill.name
  end

  # The dropdown is `position: fixed` and sized against `clientWidth`, so it
  # neither widens the document nor sticks out past a phone's right edge. Three
  # of the four form pickers used to size against `window.innerWidth - 32`, which
  # counts a scrollbar the layout cannot use.
  test "every picker's open dropdown fits a 375px phone on both forms" do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))

    { "new-session" => new_session_url, "trigger" => new_trigger_url }.each do |form, url|
      visit url
      assert_no_horizontal_overflow("#{form} form at rest")

      catalogs.each do |catalog|
        input = picker_input(catalog[:field])
        page.scroll_to(input, align: :center)
        input.click
        assert_selector "#{root(catalog[:field])} .catalog-multiselect-item", minimum: 1

        assert_empty past_right_edge(root(catalog[:field])),
          "#{catalog[:field]} picker sticks out at #{MOBILE_WIDTH}px on the #{form} form"
        assert_no_horizontal_overflow("#{form} form with the #{catalog[:field]} picker open")

        page.save_screenshot(
          Rails.root.join("tmp/screenshots/catalog-multiselect-#{form}-#{catalog[:field].dasherize}-375.png").to_s
        )
        dismiss_dropdown(catalog[:field], input)
      end
    end
  end

  # 320px is the narrowest phone the mobile QA pass asks for, and the picker has
  # a `min(max(inputWidth, 400), viewport - 16)` width formula — the one place a
  # fixed minimum could stop fitting.
  test "the pickers still fit the narrowest phone" do
    page.driver.browser.manage.window.resize_to(NARROW_WIDTH, MOBILE_HEIGHT)
    visit new_session_url

    catalogs.each do |catalog|
      input = picker_input(catalog[:field])
      page.scroll_to(input, align: :center)
      input.click
      assert_selector "#{root(catalog[:field])} .catalog-multiselect-item", minimum: 1

      assert_empty past_right_edge(root(catalog[:field])),
        "#{catalog[:field]} picker sticks out at #{NARROW_WIDTH}px"
      assert_no_horizontal_overflow("new session form with the #{catalog[:field]} picker open")

      dismiss_dropdown(catalog[:field], input)
    end
  end

  private

  def create_trigger
    trigger = Trigger.new(
      name: "catalog-multiselect-form",
      prompt_template: "Exercise the catalog pickers.",
      status: "enabled",
      agent_root_name: AgentRootsConfig.default.name
    )
    trigger.trigger_conditions.build(
      condition_type: "schedule",
      configuration: { "unit" => "hours", "interval" => 6, "timezone" => "UTC" }
    )
    trigger.save!
    trigger
  end

  # Every element inside the widget whose right edge is past the viewport.
  # `getBoundingClientRect` sees straight through `position: fixed`, which is
  # the point — the dropdown is fixed, so the document's scroll width never
  # reflects it. See catalog_multiselect_test.rb for why it is scoped.
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

  def root(field)
    "[data-catalog-field='#{field}']"
  end

  def chips(field)
    "#{root(field)} [data-catalog-multiselect-target='selectedContainer']"
  end

  def chip_keys(field)
    page.all("#{chips(field)} button[data-key]", wait: 0).map { |b| b["data-key"] }
  end

  def picker_input(field)
    find("#{root(field)} [data-catalog-multiselect-target='input']")
  end

  def hidden_input(column, value, scope: "session")
    "input[type='hidden'][name='#{scope}[#{column}][]'][value='#{value}']"
  end

  def submitted_values(column, scope: "session")
    page.all("input[type='hidden'][name='#{scope}[#{column}][]']", visible: :all, wait: 0).map(&:value)
  end

  # Escape only when there is a dropdown to close; in form mode a second Escape
  # is a no-op rather than a way out of anything.
  def dismiss_dropdown(field, input)
    return unless has_selector?("#{root(field)} .catalog-multiselect-item", wait: 0)

    input.send_keys(:escape)
    assert_no_selector "#{root(field)} .catalog-multiselect-item"
  end
end
