# frozen_string_literal: true

require "test_helper"

# The iOS UI tests wait on a predicate through `Waits.swift`, which looks once more after the
# clock runs out. A bare `XCTWaiter` does not: XCTest cancels the query it is part-way through,
# and one slow query on a loaded runner fails a wait that saw nothing (actions/runs/45603621053).
# A new test that writes its own brings that flake back, and nothing but a red `main` would say so.
class IosUiTestWaitsTest < ActiveSupport::TestCase
  SOURCES = Rails.root.join("ios/App/ZimmerUITests")
  PREDICATE_WAIT = /NSPredicateExpectation\s*\(|\bexpectation\s*\(\s*for:/

  # Where the clock is itself what is tested, so a later look would be the wrong answer. Each
  # with how many such waits it has.
  OWN_CLOCK = { "BoardStaysCurrentUITests.swift" => 2, "RowLongPress.swift" => 1 }.freeze

  def waits_by_file
    Dir.glob(SOURCES.join("**/*.swift")).to_h { |file| [ File.basename(file), File.read(file).scan(PREDICATE_WAIT).size ] }
      .reject { |_, count| count.zero? }
  end

  test "the predicate waits are in Waits.swift, so this is checking something" do
    assert_equal 1, waits_by_file["Waits.swift"]
  end

  test "a UI test waits on a predicate through Waits.swift" do
    assert_equal OWN_CLOCK, waits_by_file.except("Waits.swift"),
      "a predicate wait outside Waits.swift fails when one query outlasts its clock, whatever the " \
      "app did. Use waitForDisappearance, waitForLabel, waitForLabelContaining, waitForValue or " \
      "waitUntil. If the clock is what the test is about, add the file to OWN_CLOCK and to limitations.md"
  end
end
