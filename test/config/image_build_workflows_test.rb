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
    assert_operator attempts.length, :<=, 4,
      "#{RELEASE_WORKFLOW}: more attempts than this is not more resilience — the backoffs are " \
      "serialised inside one job that the next push queues behind"
    assert_equal attempts, attempts.sort_by { |s| steps.index(s) },
      "#{RELEASE_WORKFLOW}: attempts must appear in order — one placed above the step whose " \
      "`outcome` it reads sees an empty string there and skips forever"

    attempts.each_with_index do |attempt, i|
      last = i == attempts.length - 1
      where = "#{RELEASE_WORKFLOW}: attempt #{i + 1} ('#{attempt['name']}')"

      # Retrying a build that was never going to publish is the failure this whole
      # chain is supposed to prevent, and identical-`with` alone does not catch it:
      # `push: false` on every attempt keeps them consistent with each other.
      assert_equal true, attempt.dig("with", "push"),
        "#{where} must push — three builds that publish nothing still report green"

      if last
        assert_not attempt["continue-on-error"],
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
      # when it should not. The first attempt has nothing to wait on, so it carries no
      # `if` at all.
      expected_if = attempts.first(i).map { |prior| "steps.#{prior['id']}.outcome == 'failure'" }.join(" && ")
      if expected_if.empty?
        assert_nil attempt["if"], "#{where} is the first attempt and must run unconditionally"
      else
        assert_equal expected_if, attempt["if"],
          "#{where} must be gated on every prior attempt having failed"
      end

      assert_equal attempts.first["with"], attempt["with"],
        "#{where} must build and tag exactly what the first attempt did"
    end
  end

  # Every attempt reads its tags from one output so the attempts cannot drift apart —
  # which also means nothing in the chain would notice that output quietly losing a
  # tag. Production's auto-upgrade keys on the version tag, so dropping it publishes a
  # green release that nothing rolls out to.
  test "the release version step emits all three image tags the attempts share" do
    steps, = self.class.release_build_attempts
    compute = steps.find { |s| s["id"] == "version" }
    assert compute, "#{RELEASE_WORKFLOW}: expected the version step to carry `id: version`"

    run = compute["run"].to_s
    assert_match(/tags<<\w+/, run,
      "#{RELEASE_WORKFLOW}: the attempts read `tags` from this step, which must emit it as a " \
      "heredoc — a single-line output cannot carry three tags")
    [ "${VERSION}", "latest", "sha-${GITHUB_SHA}" ].each do |tag|
      assert_includes run, "ghcr.io/tadasant/zimmer:#{tag}",
        "#{RELEASE_WORKFLOW}: the `tags` output must still publish the :#{tag} tag"
    end
  end

  # The login talks to the same registry the attempts above retry, and it was the one link
  # in the chain with no protection at all: on 2026-09-02 run 33632998177 died on
  # `net/http: TLS handshake timeout` reaching ghcr.io/token, 48 seconds in, and every
  # step after it — buildx, the base resolve, all three build attempts, the prod notify —
  # skipped. Retrying the push half of a flaky registry while the login stays single-shot
  # leaves the release exactly as fragile as the weakest step.
  test "the release job's GHCR login retries a transient registry failure" do
    steps, attempts = self.class.release_build_attempts
    script = Rails.root.join(".github/scripts/ghcr-login.sh")

    assert script.exist?, "#{RELEASE_WORKFLOW} references #{script.basename}, which does not exist"
    assert script.executable?,
      "#{script.basename} must be executable — the workflow invokes it as a bare `run:` command, " \
      "which fails with 'Permission denied' otherwise"

    login = steps.find { |s| s["run"].to_s.include?(script.basename.to_s) }
    assert login,
      "#{RELEASE_WORKFLOW}: no step runs #{script.basename}. A single-shot login makes one bad " \
      "handshake against ghcr.io fail the whole release, however many times the build retries."
    assert_empty steps.select { |s| s["uses"].to_s.start_with?("docker/login-action@") },
      "#{RELEASE_WORKFLOW}: docker/login-action is single-shot — swapping it back in silently " \
      "undoes the retry"

    # The script derives its attempt count from this list, so an empty or non-numeric value
    # is the difference between a retry and no retry, and `sleep` would only say so at
    # runtime — on the release that was already failing.
    backoffs = login.dig("env", "LOGIN_BACKOFF_SECONDS").to_s.split
    assert_not_empty backoffs,
      "#{RELEASE_WORKFLOW}: LOGIN_BACKOFF_SECONDS drives the attempt count; empty means one attempt"
    backoffs.each do |backoff|
      assert_match(/\A\d+\z/, backoff,
        "#{RELEASE_WORKFLOW}: LOGIN_BACKOFF_SECONDS is passed straight to `sleep`, so a " \
        "non-numeric entry fails the step at runtime rather than at review time")
    end

    assert login.dig("env", "REGISTRY_PASSWORD").to_s.include?("secrets."),
      "#{RELEASE_WORKFLOW}: the login must still be handed a real token; the script refuses to " \
      "retry an empty one, but only if it is wired to a secret in the first place"

    assert_not login["continue-on-error"],
      "#{RELEASE_WORKFLOW}: once the login has spent its attempts it must fail the job — a " \
      "swallowed login failure produces an unauthenticated build that fails less legibly later"

    # Credentials must land in this job's private DOCKER_CONFIG, not the shared ~/.docker
    # that every co-tenant on the self-hosted box also writes to.
    isolate = steps.index { |s| s["run"].to_s.include?("DOCKER_CONFIG=") && s["run"].to_s.include?("RUNNER_TEMP") }
    assert_operator isolate, :<, steps.index(login),
      "#{RELEASE_WORKFLOW}: the login must run after the DOCKER_CONFIG isolation step"
    assert_operator steps.index(login), :<, steps.index(attempts.first),
      "#{RELEASE_WORKFLOW}: the login must precede the first build attempt"
  end

  # A throttled manifest read here does not fail the job — it fails CLOSED into
  # need_base=true, which escalates a read hiccup into a full base rebuild and push against
  # a registry that may already be refusing the account. Retrying the read first is what
  # keeps a hiccup from costing a base build. It cannot read the error to decide: a 404 on a
  # manifest is a shape the throttle has already worn, so "not found" is not evidence of
  # absence.
  test "the base image resolve retries its manifest read before deciding the base is missing" do
    steps, = self.class.release_build_attempts
    resolve = steps.find { |s| s["id"] == "base" }
    assert resolve, "#{RELEASE_WORKFLOW}: expected the base resolve step to carry `id: base`"

    run = resolve["run"].to_s
    inspects = run.scan(/imagetools inspect/).length
    assert_equal 1, inspects,
      "#{RELEASE_WORKFLOW}: the retry is expected to be a loop over one `imagetools inspect`, " \
      "not copies of it that can drift apart"
    assert_match(/\bfor\b.*\n.*imagetools inspect/m, run,
      "#{RELEASE_WORKFLOW}: the manifest read must sit inside a retry loop — a single-shot read " \
      "turns a registry hiccup into a full base rebuild")
    assert_match(/sleep /, run,
      "#{RELEASE_WORKFLOW}: retrying a manifest read with no backoff just re-asks a registry " \
      "that is still refusing")
    assert_includes run, "need_base=true",
      "#{RELEASE_WORKFLOW}: an exhausted retry must still fall through to rebuilding the base, " \
      "which is the behaviour that keeps a failed base build from being skipped later"
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

      # A backoff step that exits non-zero fails the job, and every later step — the
      # remaining attempts and the prod notify — then skips on its implicit success().
      # The probe reports; it must not be able to decide.
      assert_equal true, waiter["continue-on-error"],
        "#{RELEASE_WORKFLOW}: the backoff before attempt #{i + 2} must not be able to fail the " \
        "job, or a broken probe takes the whole retry chain down with it"

      assert waiter.dig("env", "ATTEMPT").present?,
        "#{RELEASE_WORKFLOW}: #{script.basename} requires ATTEMPT and exits non-zero without it"
      backoff = waiter.dig("env", "BACKOFF_SECONDS").to_s
      assert_match(/\A\d+\z/, backoff,
        "#{RELEASE_WORKFLOW}: BACKOFF_SECONDS is passed straight to `sleep`, so a non-numeric " \
        "value fails the step at runtime rather than at review time")
      assert_operator backoff.to_i, :>=, 30,
        "#{RELEASE_WORKFLOW}: a backoff this short does not outlast a GHCR secondary rate limit, " \
        "so the retry it guards just spends itself on the same throttle"
    end
  end
end
