require "application_system_test_case"

# Tests the dashboard's collapsible category sections (category_collapse Stimulus
# controller). The grid + its pagination live inside a turbo-frame that CSS hides when
# the section's <section> carries the `category-collapsed` class; the collapsed state is
# persisted to localStorage keyed by the section's stable key (a category id, or the
# "uncategorized" sentinel) so it survives a full reload.
class DashboardCategoryCollapseTest < ApplicationSystemTestCase
  def setup
    # Start from a clean slate so the only sections on the page are the ones we create.
    Notification.delete_all
    Session.destroy_all
    Category.delete_all
  end

  def create_session(category: nil, prompt: "session")
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: prompt,
      status: :running,
      agent_runtime: "claude_code",
      branch: "main",
      category: category
    )
  end

  test "collapsing a category hides its grid and persists across reload" do
    category = Category.create!(name: "Backend")
    create_session(category: category, prompt: "backend work")

    visit root_url

    section = find("section##{ActionView::RecordIdentifier.dom_id(category)}")
    frame = section.find("turbo-frame.category-collapse-body")

    # Expanded by default: the grid (inside the frame) is visible.
    assert frame.visible?, "category body should be visible before collapsing"

    # Click the chevron toggle in this section's header.
    section.find("[data-category-collapse-toggle]").click

    # The frame is hidden via the category-collapsed class on the <section>.
    assert section.matches_css?(".category-collapsed"), "section should carry category-collapsed"
    assert_not frame.visible?, "category body should be hidden after collapsing"

    # Reload: the collapsed state is restored from localStorage on connect().
    visit root_url

    section = find("section##{ActionView::RecordIdentifier.dom_id(category)}")
    assert section.matches_css?(".category-collapsed"), "collapse should persist across reload"
    # The frame is hidden (display:none) after reload, so look it up with visible: :all —
    # Capybara's default finder only matches visible elements and would raise here.
    assert_not section.find("turbo-frame.category-collapse-body", visible: :all).visible?,
      "category body should remain hidden after reload"
  end

  test "Collapse all collapses every section and persists across reload" do
    backend = Category.create!(name: "Backend")
    frontend = Category.create!(name: "Frontend")
    create_session(category: backend, prompt: "backend work")
    create_session(category: frontend, prompt: "frontend work")
    create_session(category: nil, prompt: "uncategorized work")

    visit root_url

    # The page-level toggle starts as "Collapse all".
    toggle = find("button[data-controller='collapse-all']")
    assert_text "Collapse all"

    toggle.click

    # Every section — both categories and the Uncategorized bucket — collapses.
    assert find("section##{ActionView::RecordIdentifier.dom_id(backend)}").matches_css?(".category-collapsed")
    assert find("section##{ActionView::RecordIdentifier.dom_id(frontend)}").matches_css?(".category-collapsed")
    assert find("section[data-category-collapse-key-value='uncategorized']").matches_css?(".category-collapsed")

    # The button flips to "Expand all" now that everything is collapsed.
    assert_equal "false", toggle["aria-expanded"]
    assert_text "Expand all"

    # Reload: the all-collapsed state is restored from localStorage (owned per-section).
    visit root_url

    assert find("section##{ActionView::RecordIdentifier.dom_id(backend)}").matches_css?(".category-collapsed"),
      "Backend should remain collapsed after reload"
    assert find("section##{ActionView::RecordIdentifier.dom_id(frontend)}").matches_css?(".category-collapsed"),
      "Frontend should remain collapsed after reload"
    assert find("section[data-category-collapse-key-value='uncategorized']").matches_css?(".category-collapsed"),
      "Uncategorized should remain collapsed after reload"
    # The toggle reflects the restored state and offers to expand.
    assert_text "Expand all"
  end

  test "Expand all expands every section and persists across reload" do
    backend = Category.create!(name: "Backend")
    create_session(category: backend, prompt: "backend work")
    create_session(category: nil, prompt: "uncategorized work")

    visit root_url

    toggle = find("button[data-controller='collapse-all']")

    # Collapse everything first, then expand it all back.
    toggle.click
    assert_text "Expand all"
    assert find("section##{ActionView::RecordIdentifier.dom_id(backend)}").matches_css?(".category-collapsed")

    toggle.click

    # Every section is expanded again, and the button returns to "Collapse all".
    assert_not find("section##{ActionView::RecordIdentifier.dom_id(backend)}").matches_css?(".category-collapsed")
    assert_not find("section[data-category-collapse-key-value='uncategorized']").matches_css?(".category-collapsed")
    assert_equal "true", toggle["aria-expanded"]
    assert_text "Collapse all"

    # Reload: expanded state persists (localStorage keys cleared per-section).
    visit root_url

    assert_not find("section##{ActionView::RecordIdentifier.dom_id(backend)}").matches_css?(".category-collapsed"),
      "Backend should remain expanded after reload"
    assert_not find("section[data-category-collapse-key-value='uncategorized']").matches_css?(".category-collapsed"),
      "Uncategorized should remain expanded after reload"
  end

  test "Collapse all label stays in sync after a per-section chevron toggle" do
    backend = Category.create!(name: "Backend")
    create_session(category: backend, prompt: "backend work")
    create_session(category: nil, prompt: "uncategorized work")

    visit root_url

    toggle = find("button[data-controller='collapse-all']")

    # Collapse each section individually via its own chevron.
    find("section##{ActionView::RecordIdentifier.dom_id(backend)}").find("[data-category-collapse-toggle]").click
    find("section[data-category-collapse-key-value='uncategorized']").find("[data-category-collapse-toggle]").click

    # With every section now collapsed by the per-section toggles, the page-level button
    # reflects that and offers "Expand all".
    assert_text "Expand all"
    assert_equal "false", toggle["aria-expanded"]
  end

  test "Collapse all sits on the view-mode tab row in categories view and is hidden in flat views" do
    backend = Category.create!(name: "Backend")
    create_session(category: backend, prompt: "backend work")

    # Categories view (default on desktop): the toggle renders as a peer of the
    # view-mode tab group, vertically aligned with it.
    visit root_url

    toggle = find("button[data-controller='collapse-all']")
    tab_group = find("div[role='group'][aria-label='Dashboard view mode']")
    toggle_box = toggle.native.rect
    tabs_box = tab_group.native.rect
    toggle_center = toggle_box.y + toggle_box.height / 2
    tabs_center = tabs_box.y + tabs_box.height / 2
    assert_in_delta toggle_center, tabs_center, 20,
      "Collapse all toggle should be vertically aligned with the view-mode tabs"

    # Flat sort views have no category sections, so the toggle must not render —
    # the tab group still does. (Last Touched view.)
    visit root_url(view: SessionsController::VIEW_MODE_LAST_TOUCHED)
    assert_selector "div[role='group'][aria-label='Dashboard view mode']"
    assert_no_selector "button[data-controller='collapse-all']"

    # Created view: same expectation — tab group present, toggle absent.
    visit root_url(view: SessionsController::VIEW_MODE_CREATED_DESC)
    assert_selector "div[role='group'][aria-label='Dashboard view mode']"
    assert_no_selector "button[data-controller='collapse-all']"
  end

  test "the Uncategorized bucket is independently collapsible and persistent" do
    category = Category.create!(name: "Backend")
    create_session(category: category, prompt: "categorized")
    create_session(category: nil, prompt: "uncategorized")

    visit root_url

    uncategorized = find("section[data-category-collapse-key-value='uncategorized']")
    categorized = find("section##{ActionView::RecordIdentifier.dom_id(category)}")

    # Collapse only Uncategorized.
    uncategorized.find("[data-category-collapse-toggle]").click

    assert uncategorized.matches_css?(".category-collapsed")
    # Collapsing Uncategorized must not collapse the categorized section.
    assert_not categorized.matches_css?(".category-collapsed"),
      "collapsing Uncategorized must not affect other sections"

    visit root_url

    assert find("section[data-category-collapse-key-value='uncategorized']").matches_css?(".category-collapsed"),
      "Uncategorized collapse should persist across reload"
    assert_not find("section##{ActionView::RecordIdentifier.dom_id(category)}").matches_css?(".category-collapsed"),
      "categorized section should remain expanded after reload"
  end
end
