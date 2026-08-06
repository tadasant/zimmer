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
    Dir[WORKFLOW_DIR.join("*.{yml,yaml}")].sort.flat_map do |path|
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

  RELEASE_WORKFLOW = "release-image.yml"
  # The app image build, and only it: the base-image build in the same job is gated on
  # `need_base` and tags something else, so key on the shared tag list instead.
  APP_TAGS = "${{ steps.version.outputs.tags }}"

  def self.release_build_attempts
    steps = YAML.load_file(WORKFLOW_DIR.join(RELEASE_WORKFLOW), aliases: true)
      .dig("jobs", "build-and-push", "steps")
    [ steps, steps.select { |s| s.dig("with", "tags") == APP_TAGS } ]
  end

  # The release build talks to GHCR at both ends — it pulls the zimmer-base layers on
  # the way in and pushes the finished image on the way out — and an account-wide
  # secondary rate limit has broken both. Retrying turns that into a slower green run
  # instead of a page, but only while the chain stays wired correctly: every way it can
  # come unwired ends in a workflow that publishes nothing and reports the release green.
  test "the release image build retries a registry hiccup and only the last attempt can fail the job" do
    steps, attempts = self.class.release_build_attempts

    assert_operator attempts.length, :>=, 2,
      "#{RELEASE_WORKFLOW}: the app image build must have at least one retry, or an account-wide " \
      "GHCR throttle fails the release outright"
    assert_equal attempts, attempts.sort_by { |s| steps.index(s) },
      "#{RELEASE_WORKFLOW}: attempts must appear in order — one placed above the step whose " \
      "`outcome` it reads sees an empty string there and skips forever"

    attempts.each_with_index do |attempt, i|
      last = i == attempts.length - 1
      where = "#{RELEASE_WORKFLOW}: attempt #{i + 1} ('#{attempt['name']}')"

      if last
        assert_nil attempt["continue-on-error"],
          "#{where} is the final attempt and must be allowed to fail the job — if every attempt " \
          "swallows its own failure, a release that published nothing still reports green"
      else
        assert_equal true, attempt["continue-on-error"],
          "#{where} must not fail the job by itself, or the attempts after it never run"
        assert attempt["id"].present?,
          "#{where} needs an `id` so the attempts after it can gate on its outcome"
      end

      # Attempt N runs only if every attempt before it failed. Anything looser (gating
      # on `success`, or on only the most recent failure) either never fires or fires
      # when it should not.
      expected_if = attempts.first(i).map { |prior| "steps.#{prior['id']}.outcome == 'failure'" }.join(" && ")
      assert_equal expected_if.presence, attempt["if"],
        "#{where} must be gated on every prior attempt having failed"

      assert_equal attempts.first["with"], attempt["with"],
        "#{where} must build and tag exactly what the first attempt did"
    end
  end

  # The retry is blind by design, so the backoff steps carry the diagnosis: they probe
  # GHCR and report whether the registry was answering, which is what tells a human
  # reading an exhausted run whether to suspect the registry or the build.
  test "every gap between release build attempts probes GHCR and backs off" do
    steps, attempts = self.class.release_build_attempts
    script = Rails.root.join(".github/scripts/await-ghcr.sh")

    assert script.exist?, "#{RELEASE_WORKFLOW} references #{script.basename}, which does not exist"
    assert script.executable?,
      "#{script.basename} must be executable — the workflow invokes it as a bare `run:` command, " \
      "which fails with 'Permission denied' otherwise"

    attempts.each_cons(2).with_index do |(before, after), i|
      gap = steps[(steps.index(before) + 1)...steps.index(after)]
      waiter = gap.find { |s| s["run"].to_s.include?(script.basename.to_s) }

      assert waiter,
        "#{RELEASE_WORKFLOW}: no #{script.basename} step between attempt #{i + 1} and #{i + 2} — " \
        "retrying a rate limit with no backoff just spends the next attempt on the same throttle"
      assert_equal after["if"], waiter["if"],
        "#{RELEASE_WORKFLOW}: the backoff before attempt #{i + 2} must run under exactly the " \
        "condition that attempt does, or the two disagree about when a retry is happening"
      assert waiter.dig("env", "BACKOFF_SECONDS").present? && waiter.dig("env", "ATTEMPT").present?,
        "#{RELEASE_WORKFLOW}: #{script.basename} requires BACKOFF_SECONDS and ATTEMPT and exits " \
        "non-zero without them"
    end
  end
end
