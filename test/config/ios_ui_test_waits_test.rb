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

  # Still to move to `Waits.swift`. A pull request runs every UI test class it touches, so they
  # move a few files at a time (Known limitations). A file comes off here as it moves.
  STILL_TO_MOVE = {
    "AccountUITests.swift" => 2, "AttachmentsUITests.swift" => 1, "BoardReadParityUITests.swift" => 4,
    "CarplayFitUITests.swift" => 2, "CatalogUITests.swift" => 1, "LiveHandoverUITests.swift" => 1,
    "LiveUITests.swift" => 3, "LiveUpdatesUITests.swift" => 3, "OperationsUITests.swift" => 4,
    "OptimisticActionsUITests.swift" => 1, "SessionActionsUITests.swift" => 4,
    "SessionControlsUITests.swift" => 2, "SessionDetailPanelsUITests.swift" => 4,
    "SessionExtrasUITests.swift" => 2, "SessionParityUITests.swift" => 6,
    "SessionSectionsUITests.swift" => 3, "SettingsUITests.swift" => 2,
    "TranscriptParityUITests.swift" => 5, "TriggerEditorUITests.swift" => 1
  }.freeze

  def waits_by_file
    Dir.glob(SOURCES.join("**/*.swift")).to_h { |file| [ File.basename(file), File.read(file).scan(PREDICATE_WAIT).size ] }
      .reject { |_, count| count.zero? }
  end

  test "Waits.swift has the one predicate wait the others go through, so this is checking something" do
    assert_equal 1, waits_by_file["Waits.swift"]
  end

  test "no UI test has a predicate wait of its own that is not accounted for here" do
    known = OWN_CLOCK.merge(STILL_TO_MOVE)
    found = waits_by_file.except("Waits.swift")
    added = found.select { |file, count| count > known.fetch(file, 0) }.keys
    assert_empty added,
      "#{added.join(", ")}: a predicate wait outside Waits.swift fails when one query outlasts its " \
      "clock, whatever the app did. Use waitForDisappearance, waitForLabel, waitForLabelContaining, " \
      "waitForValue or waitUntil. If the clock is what the test is about, add the file to OWN_CLOCK"

    moved = known.select { |file, count| found.fetch(file, 0) < count }.keys
    assert_empty moved, "#{moved.join(", ")}: fewer waits than listed here; lower or remove the entry"
  end
end
