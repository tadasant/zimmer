# frozen_string_literal: true

require "test_helper"
require "yaml"

# This repository is public, so every job runs on a GitHub-hosted runner, and the label is
# written out in `runs-on` rather than read from a variable or an input. A self-hosted
# runner executes whatever a pull request's workflow tells it to: a label a fork's change
# could steer — or a `self-hosted` label left in place — is a path from an outside pull
# request onto a machine somebody operates. Hosted runners are also free and unmetered on
# a public repo, so there is no quota reason to want one.
#
# See docs/operate/deploying.md, "Where CI runs".
class GithubHostedRunnersTest < ActiveSupport::TestCase
  WORKFLOW_DIR = Rails.root.join(".github/workflows")
  HOSTED_LABELS = %w[ubuntu-24.04 ubuntu-latest macos-latest].freeze

  def self.jobs
    Dir[WORKFLOW_DIR.join("*.{yml,yaml}")].sort.flat_map do |path|
      (YAML.load_file(path, aliases: true)["jobs"] || {}).map do |name, job|
        [ "#{File.basename(path)} job '#{name}'", job ]
      end
    end
  end

  test "there are workflow jobs to check" do
    assert_operator self.class.jobs.size, :>, 10,
      "found almost no jobs under .github/workflows — this test would pass while checking nothing"
  end

  test "every job runs on a hard-coded GitHub-hosted label" do
    self.class.jobs.each do |where, job|
      # A reusable-workflow call has no runner of its own; the called workflow's jobs
      # are checked where they are defined.
      next if job["uses"]

      assert_includes HOSTED_LABELS, job["runs-on"],
        "#{where}: runs-on must be one of #{HOSTED_LABELS.join(", ")}, written out literally. " \
        "Not self-hosted, and not an expression a variable or input could point elsewhere."
    end
  end

  test "every job bounds its own runtime" do
    self.class.jobs.each do |where, job|
      next if job["uses"]

      assert_kind_of Integer, job["timeout-minutes"],
        "#{where}: set timeout-minutes. GitHub's default is six hours, which a hung " \
        "service container or browser would spend in full."
    end
  end

  # ruby/setup-ruby builds only the newest patch of each Ruby series for a newer image, so
  # `ubuntu-latest` (ubuntu-26.04) has no Ruby 3.4.6 and every Ruby job dies in setup.
  test "every job that sets up Ruby pins ubuntu-24.04" do
    self.class.jobs.each do |where, job|
      next unless (job["steps"] || []).any? { |s| s["uses"].to_s.start_with?("ruby/setup-ruby@") }

      assert_equal "ubuntu-24.04", job["runs-on"],
        "#{where}: sets up Ruby, so it pins ubuntu-24.04 — a newer image has no Ruby 3.4.6 build."
    end
  end

  test "no ruby/setup-ruby step asks for a self-hosted toolcache" do
    self.class.jobs.each do |where, job|
      (job["steps"] || []).each do |step|
        next unless step["uses"].to_s.start_with?("ruby/setup-ruby@")

        assert_not step.dig("with", "self-hosted"),
          "#{where}: `self-hosted: true` makes setup-ruby look for a Ruby staged on the " \
          "runner, which a hosted runner does not have."
      end
    end
  end
end
