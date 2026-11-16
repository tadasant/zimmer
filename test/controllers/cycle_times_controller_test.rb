# frozen_string_literal: true

require "test_helper"

class CycleTimesControllerTest < ActionDispatch::IntegrationTest
  include CycleTimeFixtures

  test "index lists autonomous tasks in the window with the aggregate" do
    create_cycle_time_row(finished_at: 2.days.ago, totals: { "inference" => 300, "wait_ci" => 900 }, title: "Shipped the fix")
    create_cycle_time_row(finished_at: 20.days.ago, totals: { "inference" => 300 }, title: "Too old")
    create_cycle_time_row(finished_at: 1.day.ago, totals: { "inference" => 1 }, title: "Trashed", eligible: false, reason: "human_archive")

    get cycle_times_path

    assert_response :success
    assert_includes response.body, "Shipped the fix"
    assert_not_includes response.body, "Too old"
    assert_not_includes response.body, ">Trashed<"
    assert_includes response.body, "Waiting on CI"
    assert_includes response.body, "a human archived a session"
    assert_select "[data-cycle-segment]"
  end

  test "index honours a custom range" do
    create_cycle_time_row(finished_at: 20.days.ago, totals: { "inference" => 300 }, title: "Too old")

    get cycle_times_path(from: 25.days.ago.to_date.iso8601, to: 15.days.ago.to_date.iso8601)

    assert_includes response.body, "Too old"
  end

  test "show draws a lane per session plus the rollup, with hover data on every segment" do
    row = create_cycle_time_row(finished_at: 1.hour.ago, totals: { "inference" => 300, "wait_ci" => 900 }, title: "Shipped")

    get cycle_time_path(row.root_session_id)

    assert_response :success
    assert_includes response.body, "Whole task"
    assert_select "[data-cycle-segment][data-label][data-duration][data-window]", minimum: 2
  end

  test "show 404s for a root with no row" do
    get cycle_time_path(Session.create!(prompt: "x", git_root: "https://github.com/test/repo.git").id)

    assert_response :not_found
  end

  test "the dashboard menu links Cycle Time between Outcomes and Gate Decisions" do
    get root_path

    body = response.body
    [ body.index(">\n                Outcomes"), body.index(">\n                Cycle Time"), body.index(">\n                Gate Decisions") ].then do |positions|
      assert positions.all?, "menu entries missing"
      assert_equal positions.sort, positions
    end
    assert_select "a[href='#{cycle_times_path}']", minimum: 2
  end
end
