# frozen_string_literal: true

require "test_helper"
require "yaml"

# `all-checks-pass` is the single required status check under branch protection, and
# it only knows about the jobs named in its `needs:`. A job added to ci.yml but left
# out of that list runs on every PR, goes red on every PR, and blocks nothing — the
# same shape as the defect these assertions exist alongside, where
# `bin/rails db:schema:verify` shipped and nothing invoked it
# (https://github.com/tadasant/zimmer/issues/318).
#
# Structural, not a list of job names: a new job inherits the guard instead of having
# to remember it.
class CiGateCoverageTest < ActiveSupport::TestCase
  WORKFLOW = Rails.root.join(".github/workflows/ci.yml")
  GATE = "all-checks-pass"

  def jobs
    @jobs ||= YAML.load_file(WORKFLOW, aliases: true).fetch("jobs")
  end

  test "the aggregate gate needs every other job in ci.yml" do
    gate = jobs.fetch(GATE)
    assert_not_empty jobs.except(GATE), "ci.yml has no jobs besides #{GATE}"

    missing = jobs.keys - [ GATE ] - Array(gate["needs"])

    assert_empty missing,
      "#{missing.join(", ")} run on every PR but are not in #{GATE}'s needs:, so branch " \
      "protection ignores them. Add them, or the job gates nothing."
  end

  test "a job runs the schema round-trip check" do
    runners = jobs.values.select do |job|
      (job["steps"] || []).any? { |step| step["run"].to_s.include?("db:schema:verify") }
    end

    assert_not_empty runners,
      "no job in ci.yml runs `bin/rails db:schema:verify`. Without it nothing migrates from " \
      "zero in CI, and a db/schema.rb that disagrees with db/migrate/ is green until someone " \
      "migrates an empty database."

    assert runners.all? { |job| job.dig("services", "postgres") },
      "the job running db:schema:verify has no Postgres service container to drop and recreate."
  end
end
