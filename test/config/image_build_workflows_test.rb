# frozen_string_literal: true

require "test_helper"
require "yaml"

# Every image-building job on the shared self-hosted runner must isolate its Docker
# client state. All runner workers on that box execute as one OS user, so the default
# ~/.docker is shared mutable state: `docker buildx create --use` writes a single
# current-builder file that build-push-action later reads to pick a builder, and
# docker/login-action's post step logs out of a single shared credential store. A job
# that leaves either at the default builds on a co-tenant's buildkit container and
# dies mid-build when that co-tenant's post step removes it ("graceful_stop" GOAWAY,
# then `no builder "<other-jobs-uuid>" found`).
#
# This asserts the two guards structurally, across every workflow, so a newly added
# image build inherits them instead of rediscovering the flake.
class ImageBuildWorkflowsTest < ActiveSupport::TestCase
  WORKFLOW_DIR = Rails.root.join(".github/workflows")
  BUILD_ACTION = "docker/build-push-action"
  BUILDX_ACTION = "docker/setup-buildx-action"

  # [workflow basename, job name, job hash] for every job that builds an image.
  def self.image_build_jobs
    Dir[WORKFLOW_DIR.join("*.yml")].sort.flat_map do |path|
      jobs = YAML.load_file(path, aliases: true)["jobs"] || {}
      jobs.filter_map do |job_name, job|
        steps = job["steps"] || []
        next unless steps.any? { |s| s["uses"].to_s.start_with?("#{BUILD_ACTION}@") }

        [ File.basename(path), job_name, job ]
      end
    end
  end

  test "there is at least one image-building job to guard" do
    assert_not_empty self.class.image_build_jobs,
      "found no #{BUILD_ACTION} jobs — this test would silently pass forever"
  end

  test "every image-building job exports a private DOCKER_CONFIG before any Docker step" do
    self.class.image_build_jobs.each do |workflow, job_name, job|
      where = "#{workflow} job '#{job_name}'"
      steps = job["steps"] || []

      assert_equal "self-hosted", job["runs-on"],
        "#{where}: expected the shared self-hosted pool; revisit this guard if that changed"

      isolate = steps.index do |step|
        run = step["run"].to_s
        run.include?("DOCKER_CONFIG=") && run.include?('"$GITHUB_ENV"') &&
          run.include?("RUNNER_TEMP") && run.include?("mkdir -p")
      end
      assert isolate,
        "#{where}: must export a per-job DOCKER_CONFIG under $RUNNER_TEMP via $GITHUB_ENV, " \
        "so a concurrent job on the same runner cannot steal or delete its buildx builder"

      first_docker = steps.index { |s| s["uses"].to_s.start_with?("docker/") }
      assert_operator isolate, :<, first_docker,
        "#{where}: the DOCKER_CONFIG isolation step must run before every docker/* action, " \
        "or login and buildx still write to the shared ~/.docker"
    end
  end

  # The `runner` context is unavailable in `jobs.<id>.env` and silently expands to "",
  # which would point DOCKER_CONFIG at /docker-config. That is why the isolation above
  # is a step rather than job-level env; keep anyone from "simplifying" it back.
  test "no image-building job resolves DOCKER_CONFIG from the runner context in job env" do
    self.class.image_build_jobs.each do |workflow, job_name, job|
      value = job.dig("env", "DOCKER_CONFIG").to_s
      assert_not_includes value, "runner.",
        "#{workflow} job '#{job_name}': `runner` is not available in job-level env — " \
        "this expands to an empty string. Export DOCKER_CONFIG from a step instead."
    end
  end

  test "every image build names the builder its own job created" do
    self.class.image_build_jobs.each do |workflow, job_name, job|
      where = "#{workflow} job '#{job_name}'"
      steps = job["steps"] || []

      buildx = steps.find { |s| s["uses"].to_s.start_with?("#{BUILDX_ACTION}@") }
      assert buildx, "#{where}: builds an image but never sets up Buildx"
      assert buildx["id"].present?,
        "#{where}: the #{BUILDX_ACTION} step needs an `id` so builds can reference its output"

      expected = "${{ steps.#{buildx['id']}.outputs.name }}"
      steps.select { |s| s["uses"].to_s.start_with?("#{BUILD_ACTION}@") }.each do |step|
        assert_equal expected, step.dig("with", "builder"),
          "#{where}: step '#{step['name']}' must pass `builder: #{expected}` rather than " \
          "letting buildx infer the current builder from shared state"
      end
    end
  end
end
