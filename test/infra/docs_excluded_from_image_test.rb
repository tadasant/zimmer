# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# The docs are single-source: the only copy that exists is docs/ in this repo, built by
# Cloudflare Pages and served at docs.zimmer.tadasant.com. A second copy bundled into the
# published image would be one nobody deploys, nobody reads, and nobody keeps true.
#
# Nothing in Dockerfile is selective about it -- the build stage does a blanket `COPY . .`
# and the final stage a `COPY --from=build /rails /rails`. The docs stay out because of a
# single `/docs` line in .dockerignore, and that is a fragile place for an invariant to
# live: reorganize the file, or move the docs to another path, and the second copy comes
# back with no signal at all.
#
# scripts/assert-docs-excluded.sh is the guardrail that replaces that trust with a check.
# It runs in two places, both against a real filesystem rather than against the text of
# .dockerignore:
#
#   Dockerfile              /rails in the final stage -- the published image itself.
#                           Fails the build, so a bad image is never pushed.
#   Dockerfile.docs-audit   the real build context, in busybox, from PR CI's
#                           `image_excludes_docs` job -- the same signal, before merge.
#
# These assertions cover the half of that a Docker daemon is not needed for: that the
# detector detects (including the real docs site, so it can never pass vacuously), that it
# does not fire on trees that are fine, and that both callers are still wired up. The
# Docker-side half is the CI job itself.
class DocsExcludedFromImageTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts/assert-docs-excluded.sh")
  DOCKERFILE = Rails.root.join("Dockerfile")
  AUDIT_DOCKERFILE = Rails.root.join("Dockerfile.docs-audit")
  CI_WORKFLOW = Rails.root.join(".github/workflows/ci.yml")

  # The exact invocation each caller must keep. Both are load-bearing: an image whose
  # build no longer runs the script is an image with no guardrail on it.
  IMAGE_ASSERTION = "RUN /rails/scripts/assert-docs-excluded.sh --root /rails"
  CONTEXT_ASSERTION = "RUN /ctx/scripts/assert-docs-excluded.sh --root /ctx"

  def detect(root)
    Open3.capture2e(SCRIPT.to_s, "--root", root.to_s)
  end

  test "the script is executable, since Docker runs it directly" do
    assert File.executable?(SCRIPT), <<~MSG
      #{SCRIPT.basename} has lost its executable bit. Dockerfile and Dockerfile.docs-audit
      both invoke it as a command, so the build would fail with "permission denied".
      Restore it with: chmod +x #{SCRIPT.relative_path_from(Rails.root)}
    MSG
  end

  # The one that keeps every other assertion honest. A detector that finds nothing finds
  # nothing in the image either, and passes forever while the invariant rots.
  test "the detector finds the real docs site in this working tree" do
    output, status = detect(Rails.root)

    refute_predicate status, :success?, <<~MSG
      scripts/assert-docs-excluded.sh reported this repository as free of the docs site --
      but docs/ is right there. The detector is broken (or the docs moved and it was not
      taught the new shape), which means it would also pass on an image that DOES bundle
      them. Its output was:

      #{output}
    MSG
    assert_match %r{docs directory: .*/docs}, output
  end

  test "the detector passes a tree with no docs site" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app"))
      File.write(File.join(dir, "app/session.rb"), "class Session; end\n")
      File.write(File.join(dir, "package.json"), '{"devDependencies":{"@tailwindcss/typography":"^0.5.19"}}')

      output, status = detect(dir)

      assert_predicate status, :success?, "Expected a clean tree to pass. Output:\n#{output}"
    end
  end

  # Path-based checking alone would miss this, and a rename is the likeliest way the
  # exclusion gets lost: the .dockerignore line still says /docs, and matches nothing.
  test "the detector finds a docs site that was moved to another directory" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "documentation/src/content/docs"))
      File.write(File.join(dir, "documentation/astro.config.mjs"), "export default {}\n")

      output, status = detect(dir)

      refute_predicate status, :success?, "Expected a renamed docs tree to be caught. Output:\n#{output}"
      assert_match "documentation/astro.config.mjs", output
    end
  end

  test "the detector finds a Starlight dependency in any package manifest" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "site"))
      File.write(File.join(dir, "site/package.json"), '{"dependencies":{"@astrojs/starlight":"^0.36.0"}}')

      output, status = detect(dir)

      refute_predicate status, :success?, "Expected a Starlight dependency to be caught. Output:\n#{output}"
      assert_match "site/package.json", output
    end
  end

  # Starlight vendored under node_modules belongs to some other package's dependency tree,
  # not to a second copy of our site. Firing on it would train people to ignore this check.
  test "the detector ignores node_modules" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "node_modules/@astrojs/starlight"))
      File.write(File.join(dir, "node_modules/@astrojs/starlight/package.json"), '{"name":"@astrojs/starlight"}')
      File.write(File.join(dir, "node_modules/astro.config.mjs"), "export default {}\n")

      output, status = detect(dir)

      assert_predicate status, :success?, "Expected node_modules to be skipped. Output:\n#{output}"
    end
  end

  test "the published image build asserts the invariant against its own filesystem" do
    assert_includes File.read(DOCKERFILE), IMAGE_ASSERTION, <<~MSG
      Dockerfile no longer runs the docs guardrail. This is the assertion that inspects the
      REAL published image, and the one that stops a bad image from being pushed at all --
      it fails the build. Restore:

        #{IMAGE_ASSERTION}
    MSG
  end

  test "the build-context audit asserts the invariant" do
    assert_includes File.read(AUDIT_DOCKERFILE), CONTEXT_ASSERTION, <<~MSG
      Dockerfile.docs-audit no longer runs the docs guardrail, so CI's image_excludes_docs
      job builds an image that checks nothing and passes. Restore:

        #{CONTEXT_ASSERTION}
    MSG
  end

  test "CI runs the build-context audit and the aggregate gate requires it" do
    workflow = File.read(CI_WORKFLOW)

    assert_includes workflow, "image_excludes_docs:", <<~MSG
      The image_excludes_docs job is gone from ci.yml. Without it, a docs regression is
      only caught by the release build on main -- after merge.
    MSG
    assert_includes workflow, "--file Dockerfile.docs-audit"
    assert_match(/needs:(?:.|\n)*?^      - image_excludes_docs$/, workflow, <<~MSG)
      all-checks-pass no longer lists image_excludes_docs in `needs:`. It is the single
      required status check for branch protection, so a job missing from it can fail
      without blocking the merge.
    MSG
  end
end
