# frozen_string_literal: true

require "application_system_test_case"

# The Costs page is a stack of money tables and a form per write, read as often
# on a phone as on a laptop. Every row, every open drilldown and every open form
# has to fit 375px. Invented vendors and amounts only (OperatingCostFixtures).
class OperatingCostsMobileTest < ApplicationSystemTestCase
  include MobileOverflowAssertions
  include OperatingCostFixtures

  setup do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "the costs page fits a phone, empty and full, with its drilldowns and forms open" do
    visit operating_costs_path
    assert_selector "#costs-empty"
    assert_no_horizontal_overflow("The empty Costs page")

    seed_operating_costs!
    OperatingCostsCollectionJob.perform_now
    visit operating_costs_path
    assert_selector "#costs-by-functionality"
    assert_no_horizontal_overflow("The Costs page")
    page.save_screenshot("tmp/screenshots/operating-costs-375.png")

    # Open every drilldown and every form, the widest the page gets.
    page.execute_script("document.querySelectorAll('#operating-costs-page details').forEach((d) => d.open = true)")
    assert_no_horizontal_overflow("The Costs page with everything open")
    page.save_screenshot("tmp/screenshots/operating-costs-open-375.png")

    page.driver.browser.manage.window.resize_to(NARROW_WIDTH, MOBILE_HEIGHT)
    assert_no_horizontal_overflow("The Costs page at #{NARROW_WIDTH}px")
  end

  test "a narrowed page fits a phone too" do
    seed_operating_costs!
    OperatingCostsCollectionJob.perform_now

    visit operating_costs_path(functionality: "gateway-infra", include_external: "1")

    assert_text "functionality: gateway-infra"
    assert_no_horizontal_overflow("The narrowed Costs page")
  end
end
