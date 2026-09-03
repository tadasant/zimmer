# frozen_string_literal: true

require "test_helper"
require "yaml"

# `build-base-image.yml` refreshes everything Dockerfile.base pulls in that the
# repository does not pin: the base OS, apt, and the two `curl | sh` installers.
# `release-image.yml` owns the other half — it content-addresses the five repo inputs
# and rebuilds the base itself on the merge that changes one of them.
#
# Two failures are guarded here, and both look green while doing damage. A refresh that
# lands on a tag the release path does not resolve changes nothing downstream, so the
# monthly cron is an expensive no-op. And a refresh that publishes to the shared tags
# before verifying what it built writes an unverified image to the tag every app image
# is built FROM — where it sticks, because release-image reuses a content tag for as
# long as it exists rather than rebuilding it.
class BuildBaseImageWorkflowTest < ActiveSupport::TestCase
  BASE_WORKFLOW = Rails.root.join(".github/workflows/build-base-image.yml")
  RELEASE_WORKFLOW = Rails.root.join(".github/workflows/release-image.yml")
  DOCKERFILE_BASE = Rails.root.join("Dockerfile.base")
  BASE_INPUTS = "git ls-tree HEAD -- Dockerfile.base Gemfile Gemfile.lock mcp.json bin/preinstall-mcp-packages"

  def base_steps
    YAML.load_file(BASE_WORKFLOW, aliases: true).dig("jobs", "build-base", "steps")
  end

  def build_step
    base_steps.find { |s| s["uses"].to_s.start_with?("docker/build-push-action@") }
  end

  def verify_step
    base_steps.find { |s| s["run"].to_s.include?("verify-base-image.sh") }
  end

  def promote_step
    base_steps.find { |s| s["run"].to_s.include?("imagetools create") }
  end

  test "the refresh promotes to the content tag the app image is built from, not only :latest" do
    assert promote_step, "nothing promotes the built image; a refresh that publishes only to a " \
      "scratch tag reaches production no more than one publishing only :latest did"

    run = promote_step["run"].to_s
    assert_includes run, "zimmer-base:content-${KEY}",
      "release-image builds the app FROM zimmer-base:content-<key> and reuses that tag until an " \
      "input changes, so a refresh that misses it never reaches production"
    assert_includes run, "zimmer-base:latest",
      "Dockerfile's default BASE_IMAGE and await-ghcr.sh's probe still read :latest"
  end

  # A key computed differently from release-image's is a key nothing reads — the same
  # do-nothing failure wearing a different mask, and silent.
  test "both workflows derive the base key from identical inputs" do
    [ BASE_WORKFLOW, RELEASE_WORKFLOW ].each do |path|
      body = path.read
      assert_includes body, BASE_INPUTS,
        "#{path.basename}: must hash exactly the five repo inputs Dockerfile.base consumes"
      assert_includes body, "sha256sum | cut -c1-20",
        "#{path.basename}: must truncate the digest the same way, or the two keys never match"
      assert_includes body, "zimmer-base:content-",
        "#{path.basename}: must name the content tag built from that key"
    end
  end

  # The ordering is the whole safety property. release-image treats the presence of
  # `content-<key>` as proof that declaration built successfully and will not rebuild
  # it, so an unverified image written there is permanent until a repo input moves.
  test "nothing is published to a tag anything reads until the image has been verified" do
    steps = base_steps
    assert_equal "${{ steps.plan.outputs.scratch }}", build_step.dig("with", "tags"),
      "the build must push to the scratch tag alone — publishing the shared tags up front " \
      "means a failed verification has already poisoned them"

    scratch = steps.find { |s| s["id"] == "plan" }["run"][/scratch=(\S+)/, 1]
    assert scratch, "the plan step must emit a `scratch` output"
    assert_not_includes scratch, "content-",
      "the scratch tag must not be the content tag, or the verification guards nothing"
    assert_not_includes scratch, ":latest",
      "the scratch tag must not be :latest, which Dockerfile and await-ghcr.sh both resolve"

    assert_operator steps.index(build_step), :<, steps.index(verify_step),
      "the verification must run after the push, or it is checking a local build"
    assert_operator steps.index(verify_step), :<, steps.index(promote_step),
      "the promotion must run after the verification — that ordering is the only thing " \
      "keeping an unverified image off the tag release-image reuses forever"
    assert_not verify_step["continue-on-error"],
      "a verification that cannot fail the job lets the promotion run anyway"
  end

  # A base image is shared by every session container. One built from an unreviewed
  # branch and promoted onto the shared tags is worse than a stale one, and this
  # workflow is dispatchable from any ref.
  test "only main promotes to the shared tags" do
    plan = base_steps.find { |s| s["id"] == "plan" }["run"].to_s
    assert_match(/GITHUB_REF.*refs\/heads\/main/, plan,
      "the promotion decision must be gated on GITHUB_REF being refs/heads/main")
    assert_match(/promote=true/, plan)
    assert_match(/promote=false/, plan)

    assert_equal "steps.plan.outputs.promote == 'true'", promote_step["if"],
      "the promotion step must be gated on that decision, or every branch dispatch " \
      "overwrites the tags every session image is built from"
  end

  # Every change this workflow exists to pick up — a patched apt package, a newer
  # `claude` from the install script — lives in a layer whose cache key has not moved.
  # Restoring a cache makes the refresh replay the image it was meant to replace.
  test "the refresh build is uncached" do
    assert_nil build_step.dig("with", "cache-from"),
      "a cached refresh rebuilds nothing: the layers this workflow exists to renew are " \
      "exactly the ones whose cache keys are unchanged"
    assert_nil build_step.dig("with", "cache-to"),
      "nothing reads a cache this workflow writes — release-image scopes its base cache " \
      "separately — so writing one is multi-GB of waste"
  end

  test "the published image is pulled back from the registry before it is inspected" do
    script = Rails.root.join(".github/scripts/verify-base-image.sh")
    assert script.exist?, "#{BASE_WORKFLOW.basename} references #{script.basename}, which does not exist"
    assert script.executable?, "#{script.basename} must be executable"

    run = verify_step["run"].to_s
    assert_includes run, "docker pull",
      "the verification must pull the tag back from the registry rather than read a local image"
    assert_match(/for backoff in .*docker pull/m, run,
      "a single-shot pull turns a GHCR throttle into a red run on main; every other GHCR " \
      "read in this repo retries")
  end

  # The script refuses empty inputs, so it cannot pass vacuously — but only while the
  # extraction it is handed still finds them.
  test "the pin and entrypoint extraction matches what Dockerfile.base declares" do
    run = verify_step["run"].to_s

    # The comment strip is load-bearing and lives in the workflow, so read it from there
    # rather than restating it: Dockerfile.base's prose names versions it deliberately
    # does not install, and dropping the strip would fail every refresh on those.
    strip = run[/grep -vE '([^']+)'/, 1]
    assert strip, "the extraction must strip comment lines before matching"
    installs = DOCKERFILE_BASE.read.lines.grep_v(Regexp.new(strip)).join

    patterns = run.scan(/grep -oE '([^']+)'/).flatten
    assert_equal 2, patterns.length, "expected one extraction for pins and one for entrypoints"
    pin_pattern, entry_pattern = patterns

    pins = []
    installs.scan(Regexp.new(pin_pattern)) { pins << Regexp.last_match(0) }
    %w[
      @earendil-works/pi-coding-agent@0.84.4
      @pulsemcp/air-adapter-pi@0.13.0
      pi-mcp-adapter@2.32.1
      @tadasant/pi-hooks@0.1.0
      @tadasant/pi-plugins@0.1.0
    ].each do |pin|
      assert_includes pins, pin,
        "the extraction must still find #{pin} in Dockerfile.base's install lines"
    end

    # Dockerfile.base's prose names versions it deliberately does NOT install. Matching
    # those would fail every refresh on packages that were never meant to be there.
    assert_not_includes pins, "puppeteer@25.0.0",
      "the extraction must read install lines, not the comments explaining a pin"

    entries = []
    installs.scan(Regexp.new(entry_pattern)) { entries << Regexp.last_match(0) }
    entries = entries.map { |e| e.sub(/\Atest -f /, "") }
    assert_equal 3, entries.uniq.length,
      "expected the three Pi extension entrypoints Dockerfile.base smoke-checks"
    entries.each do |path|
      assert path.start_with?("/opt/pi-extensions/"),
        "#{path} is not an absolute path inside the image; the script would report it missing"
    end
  end
end
