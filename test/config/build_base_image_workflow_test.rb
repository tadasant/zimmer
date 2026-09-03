# frozen_string_literal: true

require "test_helper"
require "yaml"

# `build-base-image.yml` is the refresh path for everything Dockerfile.base pulls in
# that the repository does not pin: the base OS, apt, and the two `curl | sh`
# installers. `release-image.yml` handles the other half — it content-addresses the
# five repo inputs and rebuilds the base itself on the merge that changes one of them.
#
# The failure this guards is the refresh that runs, goes green, and changes nothing
# downstream: it published only `:latest`, and the release path stopped reading
# `:latest` when content addressing landed. A refresh has to land on the tag the app
# image is actually built FROM, and it has to be a real rebuild rather than a cache
# replay, or the monthly cron is an expensive no-op.
class BuildBaseImageWorkflowTest < ActiveSupport::TestCase
  BASE_WORKFLOW = Rails.root.join(".github/workflows/build-base-image.yml")
  RELEASE_WORKFLOW = Rails.root.join(".github/workflows/release-image.yml")
  BASE_INPUTS = "git ls-tree HEAD -- Dockerfile.base Gemfile Gemfile.lock mcp.json bin/preinstall-mcp-packages"

  def base_steps
    YAML.load_file(BASE_WORKFLOW, aliases: true).dig("jobs", "build-base", "steps")
  end

  def build_step
    base_steps.find { |s| s["uses"].to_s.start_with?("docker/build-push-action@") }
  end

  test "the refresh publishes the content tag the app image is built from, not only :latest" do
    tags = base_steps.find { |s| s["id"] == "tags" }
    assert tags, "expected a step with `id: tags` resolving what this run publishes"

    run = tags["run"].to_s
    assert_includes run, "zimmer-base:content-${BASE_KEY}",
      "a refresh that publishes only :latest never reaches production — release-image builds " \
      "the app FROM zimmer-base:content-<key> and reuses that tag until an input changes"
    assert_includes run, "zimmer-base:latest",
      "Dockerfile's default BASE_IMAGE and await-ghcr.sh's probe still read :latest"
    assert_equal "${{ steps.tags.outputs.tags }}", build_step.dig("with", "tags"),
      "the build must publish exactly the tags that step resolved"
  end

  # A key computed differently from release-image's is a key nothing reads, which is
  # the same do-nothing failure wearing a different mask — and it would be silent.
  test "both workflows derive the base key from identical inputs" do
    base = BASE_WORKFLOW.read
    release = RELEASE_WORKFLOW.read

    [ [ BASE_WORKFLOW, base ], [ RELEASE_WORKFLOW, release ] ].each do |path, body|
      assert_includes body, BASE_INPUTS,
        "#{path.basename}: must hash exactly the five repo inputs Dockerfile.base consumes"
      assert_includes body, "sha256sum | cut -c1-20",
        "#{path.basename}: must truncate the digest the same way, or the two keys never match"
      assert_includes body, "zimmer-base:content-${BASE_KEY}",
        "#{path.basename}: must name the content tag from that key"
    end
  end

  # A base image is shared by every session container. One built from an unreviewed
  # branch and pushed to the shared tags is a worse outcome than a stale base, and the
  # workflow is dispatchable from any ref.
  test "only main may publish the shared base tags" do
    run = base_steps.find { |s| s["id"] == "tags" }["run"].to_s
    guard = run[/if \[ "\$\{GITHUB_REF\}" = "refs\/heads\/main" \]; then\n(.*?)\n\s*else\n(.*?)\n\s*fi/m]
    assert guard,
      "the tag list must branch on GITHUB_REF being refs/heads/main"

    on_main, off_main = Regexp.last_match(1), Regexp.last_match(2)
    [ "content-", "latest" ].each do |shared|
      assert_includes on_main, shared, "main must still publish the #{shared} tag"
      assert_not_includes off_main, "zimmer-base:#{shared}",
        "a dispatch from a feature branch must not publish zimmer-base:#{shared}"
    end
    assert_includes off_main, "zimmer-base:branch-",
      "a non-main dispatch should still publish somewhere, or it cannot be verified at all"
  end

  # Every change this workflow exists to pick up — a patched apt package, a newer
  # `claude` from the install script — lives in a layer whose cache key did not move.
  # Restoring a cache here makes the refresh replay the image it was meant to replace.
  test "the refresh build is uncached" do
    assert_nil build_step.dig("with", "cache-from"),
      "a cached refresh rebuilds nothing: the layers this workflow exists to renew are " \
      "exactly the ones whose cache keys are unchanged"
    assert_nil build_step.dig("with", "cache-to"),
      "nothing reads a cache this workflow writes — release-image scopes its base cache " \
      "separately — so writing one is multi-GB of waste"
  end

  # `test -f` inside Dockerfile.base says a layer was produced. It does not say the tag
  # the release path resolves now serves that layer, which is the gap that let
  # @tadasant/pi-hooks and @tadasant/pi-plugins be pinned on 2026-09-03 with nothing
  # downstream asserting they had arrived.
  test "the published image is verified against Dockerfile.base's pins after the push" do
    script = Rails.root.join(".github/scripts/verify-base-image.sh")
    assert script.exist?, "#{BASE_WORKFLOW.basename} references #{script.basename}, which does not exist"
    assert script.executable?, "#{script.basename} must be executable"

    steps = base_steps
    verify = steps.find { |s| s["run"].to_s.include?(script.basename.to_s) }
    assert verify, "nothing verifies the pushed image; a pin nobody checks after the push is how " \
      "'pinned' and 'present in the image' drifted apart"
    assert_operator steps.index(build_step), :<, steps.index(verify),
      "the verification must run after the push, or it is checking a local build"
    assert_includes verify["run"].to_s, "docker pull",
      "the verification must pull the tag back from the registry rather than read a local image"
    assert_not verify["continue-on-error"],
      "a verification that cannot fail the job reports a broken base image as a green run"
  end

  # The script refuses an empty pin list, so the one way it could pass vacuously is
  # closed — but only while the extraction it is handed still finds the pins. A
  # reformat of Dockerfile.base that moved an install onto a line this pattern no
  # longer matches would quietly shrink what gets checked.
  test "the pin extraction matches what Dockerfile.base actually installs" do
    verify = base_steps.find { |s| s["run"].to_s.include?("verify-base-image.sh") }
    pattern = verify["run"][/grep -oE '([^']+)'/, 1]
    assert pattern, "expected the pin extraction to use a grep -oE pattern"

    # Mirror the shell: strip comment lines first, then scan. `scan` with a block sets
    # $~, which is how the whole match is read out of a pattern that has its own groups.
    installs = Rails.root.join("Dockerfile.base").read.lines.grep_v(/\A\s*#/).join
    pins = []
    installs.scan(Regexp.new(pattern)) { pins << Regexp.last_match(0) }

    %w[
      @earendil-works/pi-coding-agent@0.84.4
      @pulsemcp/air-adapter-pi@0.13.0
      pi-mcp-adapter@2.32.1
      @tadasant/pi-hooks@0.1.0
      @tadasant/pi-plugins@0.1.0
    ].each do |pin|
      assert_includes pins, pin,
        "the workflow's extraction must still find #{pin} in Dockerfile.base's install lines"
    end

    # Dockerfile.base's prose names versions it deliberately does NOT install. Matching
    # those would fail every base build on packages that were never meant to be there.
    assert_not_includes pins, "puppeteer@25.0.0",
      "the extraction must read install lines, not the comments explaining a pin"
  end
end
