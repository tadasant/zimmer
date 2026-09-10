require "application_system_test_case"

# Dragging a session card to a new position inside a section, and finding it still
# there after a full reload. The write is POST /sessions/reorder, driven by the
# category_dnd Stimulus controller; the read is Session.card_ordered.
class DashboardCardOrderTest < ApplicationSystemTestCase
  def setup
    Notification.delete_all
    Session.destroy_all
    Category.delete_all
    AppSetting.delete_all
  end

  # `needs_input` because that is the dashboard's default status filter — a card in
  # any other state is filtered out of the grid entirely.
  def create_session(title:, created_at:, category: nil)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: title,
      title: title,
      status: :needs_input,
      agent_runtime: "claude_code",
      branch: "main",
      created_at: created_at,
      category: category
    )
  end

  # The card ids rendered in one grid, top-to-bottom.
  def card_ids(grid_id)
    page.evaluate_script(<<~JS)
      Array.from(document.getElementById(#{grid_id.to_json}).children)
        .map((child) => child.id.replace("session_", ""))
    JS
  end

  # Poll a condition the way Capybara's own matchers do. The reorder POST is fired
  # from the drop handler and answered asynchronously, so a bare read of the row
  # immediately after the drag races the request.
  def wait_until(timeout: 5)
    deadline = Time.current + timeout
    loop do
      value = yield
      return value if value
      raise Minitest::Assertion, "condition not met within #{timeout}s" if Time.current > deadline
      sleep 0.1
    end
  end

  # A real press-and-move through the driver, not dispatched MouseEvents: SortableJS
  # binds `pointerdown`, and a synthetic MouseEvent never reaches it, so a scripted
  # "drag" would silently prove nothing. Selenium's Actions API does not scroll to its
  # target the way `click` does, so the grid is scrolled into view first.
  def drag_card_onto(source_id, target_id)
    page.execute_script(
      "document.getElementById(#{"session_#{source_id}".to_json}).scrollIntoView({ block: 'center' })"
    )
    handle = find("#session_#{source_id} .session-drag-handle")
    target = find("#session_#{target_id}")

    page.driver.browser.action
      .move_to(handle.native)
      .click_and_hold
      .move_by(0, 10)
      .move_to(target.native)
      .move_by(0, -10)
      .release
      .perform
  end

  test "a within-section drag survives a full reload" do
    older = create_session(title: "Older card", created_at: 2.hours.ago)
    newer = create_session(title: "Newer card", created_at: 1.hour.ago)

    visit root_url
    assert_selector "#session_#{older.id}"
    # Newest first, before anyone drags anything.
    assert_equal [ newer.id.to_s, older.id.to_s ], card_ids("sessions_grid")

    drag_card_onto(older.id, newer.id)

    assert_equal [ older.id.to_s, newer.id.to_s ], card_ids("sessions_grid")
    # The write landed server-side, not just in the DOM.
    wait_until do
      Session.where(category_id: nil).card_ordered.pluck(:id) == [ older.id, newer.id ]
    end

    visit root_url
    assert_selector "#session_#{older.id}"
    assert_equal [ older.id.to_s, newer.id.to_s ], card_ids("sessions_grid")
  end

  test "the dragged order survives navigating away and back" do
    older = create_session(title: "Older card", created_at: 2.hours.ago)
    newer = create_session(title: "Newer card", created_at: 1.hour.ago)

    visit root_url
    assert_selector "#session_#{older.id}"
    drag_card_onto(older.id, newer.id)
    assert_equal [ older.id.to_s, newer.id.to_s ], card_ids("sessions_grid")

    # Open a session, then come back — the "page moves" half of the requirement.
    wait_until do
      Session.where(category_id: nil).card_ordered.pluck(:id) == [ older.id, newer.id ]
    end
    visit session_url(newer)
    assert_selector "h1", text: "Newer card", wait: 10
    visit root_url

    assert_selector "#session_#{older.id}"
    assert_equal [ older.id.to_s, newer.id.to_s ], card_ids("sessions_grid")
  end

  test "a cross-section drag persists the category and the position together" do
    inbox = Category.create!(name: "Inbox")
    resident = create_session(title: "Resident card", created_at: 2.hours.ago, category: inbox)
    stray = create_session(title: "Stray card", created_at: 1.hour.ago)

    visit root_url
    assert_selector "#session_#{stray.id}"
    assert_equal [ stray.id.to_s ], card_ids("sessions_grid")

    drag_card_onto(stray.id, resident.id)

    assert_equal [ stray.id.to_s, resident.id.to_s ], card_ids("category_grid_#{inbox.id}")
    wait_until { stray.reload.category_id == inbox.id }
    wait_until do
      Session.where(category_id: inbox.id).card_ordered.pluck(:id) == [ stray.id, resident.id ]
    end

    visit root_url
    assert_selector "#session_#{stray.id}"
    assert_equal [ stray.id.to_s, resident.id.to_s ], card_ids("category_grid_#{inbox.id}")
    assert_empty card_ids("sessions_grid")
  end
end
