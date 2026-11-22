# frozen_string_literal: true

require "application_system_test_case"

# Your board v2 in a real browser. The drags are the part an integration test
# cannot prove: SortableJS is driven by its own pointer events, so these press,
# move and release through the driver and then read the database.
class BoardV2Test < ApplicationSystemTestCase
  TAG = "Zboardv2fixture".freeze

  setup do
    # Tall enough that the dragged handle and its drop target share the viewport:
    # driver actions do not scroll.
    page.driver.browser.manage.window.resize_to(1400, 1600)
    @infra = BoardCategory.create!(name: "#{TAG} Infra")
    @research = BoardCategory.create!(name: "#{TAG} Research")
    @loose = make("loose one")
    @infra_row = make("infra one", category: @infra)
    @research_row = make("research one", category: @research)
  end

  def make(title, category: nil)
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "x",
      title: "#{TAG} #{title}", status: :needs_input)
    session.update_columns(board_category_id: category&.id)
    session
  end

  def visit_board
    visit root_path(view: SessionsController::VIEW_MODE_BOARD_V2, q: TAG)
    assert_selector "#board_v2"
    wait_until_armed
  end

  def wait_until_armed(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      armed = page.evaluate_script(<<~JS)
        (() => {
          const cats = document.querySelector("[data-board-v2-target='categories']")
          const lists = document.querySelectorAll("[data-board-v2-target='list']")
          return !!(cats && cats.sortableInstance) && lists.length > 0 &&
            Array.from(lists).every((l) => l.sortableInstance)
        })()
      JS
      return if armed
      raise "Your board v2's drag-and-drop never armed within #{timeout}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  # Press the handle at `handle_css`, walk the pointer to `onto_css` in steps
  # (SortableJS's fallback tracks pointer moves, not a teleport), pause so its
  # emulated dragover sees the pointer there, and release.
  #
  # Steps are fixed viewport points, not offsets from the target: a category
  # dragged above another pushes that one down, and a pointer re-aimed at its
  # new position would follow it and swap them straight back.
  #
  # Takes selectors rather than elements and re-finds them on a stale reference:
  # the board is a turbo-frame, and the reconnect backfill can swap it for a
  # fresh copy between the find and the press.
  def drag(handle_css, onto_css, dy: 0)
    attempts = 0
    begin
      page.execute_script("document.getElementById('board_v2').scrollIntoView({ block: 'start' })")
      from = viewport_centre(handle_css)
      to = viewport_centre(onto_css)
      to_y = to[1] + dy
      action = page.driver.browser.action.move_to_location(from[0], from[1]).click_and_hold
      action = action.move_to_location(from[0], from[1] + 8)
      steps = 12
      (1..steps).each do |i|
        fraction = i.to_f / steps
        action = action.move_to_location((from[0] + ((to[0] - from[0]) * fraction)).to_i,
          (from[1] + 8 + ((to_y - from[1] - 8) * fraction)).to_i)
      end
      action.pause(duration: 0.3).release.perform
    rescue Selenium::WebDriver::Error::StaleElementReferenceError
      attempts += 1
      raise if attempts > 3

      wait_until_armed
      retry
    end
  end

  def viewport_centre(css)
    find(css)
    page.evaluate_script(<<~JS)
      (() => {
        const r = document.querySelector(#{css.to_json}).getBoundingClientRect()
        return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)]
      })()
    JS
  end

  def wait_for(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.1 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    yield
  end

  test "dragging a row into another category saves it" do
    visit_board
    drag("#user_view_row_#{@loose.id} [data-board-v2-target='handle']", "#user_view_row_#{@research_row.id}")

    assert_selector "#board_v2_list_#{@research.id} #user_view_row_#{@loose.id}"
    assert wait_for { @loose.reload.board_category_id == @research.id }, "the drop was not saved"
  end

  test "dragging a category header reorders categories and survives a reload" do
    visit_board
    drag("[data-board-v2-target='category'][data-category-id='#{@research.id}'] [data-board-v2-category-handle]",
      "[data-board-v2-target='category'][data-category-id='#{@infra.id}'] h3", dy: -6)

    assert wait_for { BoardCategory.ordered.where(id: [ @infra.id, @research.id ]).pluck(:id) == [ @research.id, @infra.id ] },
      "the category order was not saved"
    visit_board
    order = all("[data-board-v2-target='category']").map { |el| el["data-category-id"].to_i }
    assert_equal [ @research.id, @infra.id ], order & [ @research.id, @infra.id ]
  end

  test "collapsing a category survives a reload" do
    visit_board
    find("[data-board-v2-target='category'][data-category-id='#{@infra.id}'] button[data-action='board-v2#toggle']").click

    assert wait_for { @infra.reload.collapsed }, "the collapse was not saved"
    visit_board
    assert_selector "[data-category-id='#{@infra.id}'] [data-board-v2-body].hidden", visible: :all
    assert_no_selector "#user_view_row_#{@infra_row.id}"
  end
end
