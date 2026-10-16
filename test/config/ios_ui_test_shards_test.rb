# frozen_string_literal: true

require "test_helper"
require "yaml"

# The `ios` job in ci.yml runs the XCUITest suite as three shards, each a `--only` list
# of test classes handed to `ios/bin/ui-test`. A class is only run if a shard names it,
# so a class added under ios/App/ZimmerUITests and left out of the matrix passes on the
# laptop that wrote it and then never runs again — green forever, exercised never. And a
# class named twice runs twice, which costs the minutes the split exists to save.
#
# Read from both sources rather than a list kept here: the classes from the Swift files,
# the shards from the workflow. A new class is covered the moment it is written, and this
# runs in the Linux `test-unit` job, which needs no Mac.
class IosUiTestShardsTest < ActiveSupport::TestCase
  WORKFLOW = Rails.root.join(".github/workflows/ci.yml")
  SOURCES = Rails.root.join("ios/App/ZimmerUITests")
  # Any XCTestCase subclass, `final` or not, however it spaces the colon: a class this
  # misses is one that never runs and is never reported missing. `ios/bin/ui-test` accepts
  # the same shape in `--only`.
  CLASS = /^(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase/

  def shards
    @shards ||= YAML.load_file(WORKFLOW, aliases: true).dig("jobs", "ios", "strategy", "matrix", "shard")
  end

  def classes_in_sources
    Dir.glob(SOURCES.join("**/*.swift")).flat_map { |file| File.read(file).scan(CLASS).flatten }
  end

  def classes_by_shard
    shards.to_h { |shard| [ shard.fetch("name"), shard.fetch("classes").split(",").map(&:strip) ] }
  end

  test "the sources define UI test classes and the matrix has shards, so this is checking something" do
    assert_includes classes_in_sources, "SessionListUITests"
    assert_operator shards.size, :>=, 2, "the ios job is not a matrix of shards"
  end

  test "every UI test class is in exactly one shard" do
    named = classes_by_shard.values.flatten
    sources = classes_in_sources

    missing = sources - named
    assert_empty missing,
      "#{missing.join(", ")} #{missing.one? ? "is" : "are"} under ios/App/ZimmerUITests but in no " \
      "shard of the ios job's matrix in #{WORKFLOW.relative_path_from(Rails.root)}, so CI never " \
      "runs #{missing.one? ? "it" : "them"}. Add #{missing.one? ? "it" : "each"} to the lightest " \
      "shard's `classes:`"

    twice = named.tally.select { |_, n| n > 1 }.keys
    assert_empty twice, "#{twice.join(", ")} named in more than one shard; each class runs once"

    unknown = named - sources
    assert_empty unknown,
      "#{unknown.join(", ")} named in a shard but not defined as `final class …: XCTestCase` " \
      "under ios/App/ZimmerUITests; ios/bin/ui-test refuses the shard, and the job fails before " \
      "it builds"
  end

  test "a single shard takes the photographs" do
    photographing = shards.select { |shard| shard["photos"] == true }.map { |shard| shard["name"] }
    assert_equal 1, photographing.size,
      "the photograph pass runs on #{photographing.empty? ? "no shard" : photographing.join(" and ")}; " \
      "exactly one shard carries it, and that is the artifact a PR body embeds"
  end

  test "each shard keeps its own artifact and one shard's failure does not cancel the rest" do
    job = YAML.load_file(WORKFLOW, aliases: true).dig("jobs", "ios")
    assert_equal false, job.dig("strategy", "fail-fast"), "fail-fast must be false: a cancelled shard has no evidence"
    upload = job["steps"].find { |step| step["uses"].to_s.start_with?("actions/upload-artifact") }
    assert_includes upload.dig("with", "name"), "matrix.shard.name",
      "three shards uploading one artifact name fail on the second upload"
  end
end
