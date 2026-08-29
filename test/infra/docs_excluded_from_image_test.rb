# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "yaml"

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
  DOCKERIGNORE = Rails.root.join(".dockerignore")

  # The real `find`, resolved once so the shims below can hand off to it. Resolving it
  # through a plain `sh` keeps any interactive shell's `find` alias out of the answer.
  REAL_FIND = Open3.capture2("sh", "-c", "command -v find").first.strip

  # The shim tests run without the retry delay: they exercise all three attempts, and
  # three real seconds per test is wall clock every CI run of the unit suite pays for
  # nothing. The attempt COUNT is deliberately not overridable, here or in the script.
  NO_RETRY_DELAY = { "SCAN_RETRY_DELAY" => "0" }.freeze

  # The exact invocation each caller must keep. Both are load-bearing: an image whose
  # build no longer runs the script is an image with no guardrail on it.
  IMAGE_ASSERTION = "RUN /rails/scripts/assert-docs-excluded.sh --root /rails"
  CONTEXT_ASSERTION = "RUN /ctx/scripts/assert-docs-excluded.sh --root /ctx"

  def detect(root, env = {})
    Open3.capture2e(env, SCRIPT.to_s, "--root", root.to_s)
  end

  # Installs `body` as a `find` ahead of the real one on PATH, and returns the env that
  # puts it there. The shims below stand in for conditions that are real but racy to
  # provoke for real -- a directory disappearing mid-walk, a manifest deleted between the
  # find that listed it and the grep that reads it.
  def with_find_shim(dir, body)
    refute_empty REAL_FIND, "Could not resolve the real `find`, which every shim below execs."

    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "find"), body)
    File.chmod(0o755, File.join(bin, "find"))
    NO_RETRY_DELAY.merge("PATH" => "#{bin}:#{ENV['PATH']}")
  end

  # How many times a shim that counts its invocations was called.
  def shim_calls(dir)
    File.exist?(File.join(dir, "calls")) ? File.read(File.join(dir, "calls")).to_i : 0
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

  # A scan that could not run is not a scan that found nothing. This is the failure mode
  # that would make every other assertion here worthless: the guardrail keeps reporting
  # OK while its own machinery is broken, and it looks exactly like a passing check.
  test "a scan that cannot run fails loudly instead of reporting a clean tree" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tree/site"))
      File.write(File.join(dir, "tree/site/package.json"), '{"dependencies":{"@astrojs/starlight":"^0.36.0"}}')

      # A `find` that always errors, ahead of the real one on PATH, counting its calls.
      env = with_find_shim(dir, <<~SHIM)
        #!/bin/sh
        n=$(cat #{dir}/calls 2>/dev/null || echo 0)
        echo $((n + 1)) > #{dir}/calls
        exit 9
      SHIM

      output, status = detect(File.join(dir, "tree"), env)

      assert_equal 2, status.exitstatus, <<~MSG
        With a broken `find`, the detector should have exited 2. Instead it exited
        #{status.exitstatus} on a tree that DOES contain a Starlight dependency. Output:

        #{output}
      MSG
      assert_match "after 3 attempts", output, <<~MSG
        The retry that absorbs a vanishing directory must not absorb a find that cannot
        run: a permanent failure is expected to exhaust every attempt and say so. Output:

        #{output}
      MSG
      assert_equal 3, shim_calls(dir), <<~MSG
        The script gave up after #{shim_calls(dir)} call(s) to a permanently broken find,
        not the 3 it claims. Retrying fewer times than advertised makes the message a lie;
        retrying more would mean the bound is not the bound.
      MSG
    end
  end

  # The flake this guards against: the detector runs over the live working tree while the
  # rest of the suite creates and deletes tmp/ scratch directories, and a directory that
  # vanishes between find's readdir and its stat makes find exit non-zero. That is the
  # tree changing underneath the scan, not a scan that could not run -- the two are told
  # apart by retrying, since only the second one fails every attempt.
  test "a find that fails transiently is retried rather than reported as a broken scan" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tree/site"))
      File.write(File.join(dir, "tree/site/package.json"), '{"dependencies":{"@astrojs/starlight":"^0.36.0"}}')

      # Fails the first two invocations the way a vanished directory does, then works.
      env = with_find_shim(dir, <<~SHIM)
        #!/bin/sh
        n=$(cat #{dir}/calls 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > #{dir}/calls
        if [ "$n" -le 2 ]; then
          echo "find: '#{dir}/tree/gone': No such file or directory" >&2
          exit 1
        fi
        exec #{REAL_FIND} "$@"
      SHIM

      output, status = detect(File.join(dir, "tree"), env)

      assert_equal 1, status.exitstatus, <<~MSG
        A find that failed twice and then succeeded should have been retried into a real
        answer -- the Starlight dependency in the tree. Instead the detector exited
        #{status.exitstatus}. Output:

        #{output}
      MSG
      assert_match "site/package.json", output, <<~MSG
        The retry returned, but with nothing in it. A scan that is retried has to report
        what the successful attempt found, not an empty result. Output:

        #{output}
      MSG
    end
  end

  # The other half of the same race, one step later: find lists a manifest, and it is gone
  # by the time grep opens it. Tolerating that is safe *because* it is exact -- the file is
  # checked for existence rather than grep's message being pattern-matched.
  test "a manifest that vanished between the find and the grep does not fail the scan" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tree/site"))
      File.write(File.join(dir, "tree/site/package.json"), '{"dependencies":{"@astrojs/starlight":"^0.36.0"}}')

      # A find that also lists a manifest which no longer exists.
      env = with_find_shim(dir, <<~SHIM)
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = "package.json" ]; then
            printf '%s\\n' "#{dir}/tree/vanished/package.json"
          fi
        done
        exec #{REAL_FIND} "$@"
      SHIM

      output, status = detect(File.join(dir, "tree"), env)

      assert_equal 1, status.exitstatus, <<~MSG
        A manifest that disappeared mid-scan should not have turned into "could not read a
        package manifest". The detector exited #{status.exitstatus}. Output:

        #{output}
      MSG
      assert_match "site/package.json", output, "The real manifest still had to be reported.\n#{output}"
    end
  end

  # ...and the inverse, which is what keeps the tolerance above from hollowing the check
  # out: a manifest that is still on disk and still unreadable is a scan that failed.
  test "a manifest that exists but cannot be read still fails loudly" do
    skip "root can read anything, so an unreadable file cannot be staged" if Process.uid.zero?

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "site"))
      File.write(File.join(dir, "site/package.json"), '{"dependencies":{"@astrojs/starlight":"^0.36.0"}}')
      File.chmod(0o000, File.join(dir, "site/package.json"))

      output, status = detect(dir)

      assert_equal 2, status.exitstatus, <<~MSG
        An unreadable manifest is a manifest this check did not read, and it must exit 2
        rather than pass the tree. It exited #{status.exitstatus}. Output:

        #{output}
      MSG
      assert_match "could not read a package manifest", output, <<~MSG
        It exited 2, but for the wrong reason -- every failure path in the script exits 2,
        so the status alone does not prove the manifest guard is what fired. Output:

        #{output}
      MSG
    end
  end

  # The two directories a running suite scribbles scratch dirs into, and the reason this
  # check stopped reddening on a race with unrelated tests.
  test "the volatile top-level directories are not walked" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tmp/test_skills_deadbeef"))
      File.write(File.join(dir, "tmp/test_skills_deadbeef/astro.config.mjs"), "export default {}\n")
      FileUtils.mkdir_p(File.join(dir, "log/cache"))
      File.write(File.join(dir, "log/cache/package.json"), '{"dependencies":{"@astrojs/starlight":"^0.36.0"}}')

      output, status = detect(dir)

      assert_predicate status, :success?, "Expected tmp/ and log/ to be skipped. Output:\n#{output}"
    end
  end

  # What the prune costs is not the same for both callers, and this pins the half that is
  # free: with these rules in place nothing under tmp/ or log/ reaches the build context,
  # so Dockerfile.docs-audit's scan skips ground that is provably empty. (The Dockerfile
  # caller scans the built image, where /rails/tmp holds what the build's RUN steps wrote
  # -- a narrow blind spot, recorded in docs/src/content/docs/limitations.md.)
  test "dockerignore keeps the pruned directories out of the build context" do
    ignored = File.read(DOCKERIGNORE).lines.map(&:strip)

    %w[/tmp/* /log/*].each do |rule|
      assert_includes ignored, rule, <<~MSG
        scripts/assert-docs-excluded.sh prunes the top-level tmp/ and log/ from its scans.
        This line is what makes that free for the build-context audit: with it, nothing
        under them is in the context to miss. Remove it and the prune widens into a hole
        on both callers instead of one. Restore #{rule}, or stop pruning it.
      MSG
    end
  end

  # The prune is anchored to the top of the tree, not matched by name: a docs site that
  # was moved into some nested tmp/ is still a docs site in the image.
  test "a nested tmp directory is still walked" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "site/tmp"))
      File.write(File.join(dir, "site/tmp/astro.config.mjs"), "export default {}\n")

      output, status = detect(dir)

      refute_predicate status, :success?, "Expected a nested tmp/ to be scanned. Output:\n#{output}"
      assert_match "site/tmp/astro.config.mjs", output
    end
  end

  # find's -path takes a glob, so an unescaped root containing a metacharacter would make
  # the top-level prune match further down as well -- "/a*b/tmp" also matches
  # "/a*b/sub/tmp", swallowing the nested tmp/ the test above insists on.
  test "a root containing glob metacharacters prunes only its own top-level tmp" do
    Dir.mktmpdir do |parent|
      dir = File.join(parent, "a*b")
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      File.write(File.join(dir, "tmp/astro.config.mjs"), "export default {}\n")
      FileUtils.mkdir_p(File.join(dir, "sub/tmp"))
      File.write(File.join(dir, "sub/tmp/astro.config.mjs"), "export default {}\n")

      output, status = detect(dir)

      refute_predicate status, :success?, <<~MSG
        The nested sub/tmp/ was pruned along with the top-level one, because the root's
        `*` leaked into find's -path glob. Output:

        #{output}
      MSG
      assert_match "sub/tmp/astro.config.mjs", output
      refute_match %r{a\*b/tmp/astro\.config\.mjs}, output, "The top-level tmp/ should still be pruned."
    end
  end

  test "a usage error is refused rather than silently scanning nothing" do
    _, no_root = Open3.capture2e(SCRIPT.to_s)
    assert_equal 2, no_root.exitstatus, "Expected --root to be required."

    _, bad_flag = Open3.capture2e(SCRIPT.to_s, "--everything")
    assert_equal 2, bad_flag.exitstatus, "Expected an unknown argument to be refused."

    _, missing_dir = Open3.capture2e(SCRIPT.to_s, "--root", "/nonexistent-tree")
    assert_equal 2, missing_dir.exitstatus, <<~MSG
      Expected a nonexistent --root to exit 2. Treating it as an empty tree would make a
      typo in either Dockerfile read as "no docs here" forever.
    MSG
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
    jobs = YAML.safe_load(File.read(CI_WORKFLOW)).fetch("jobs")

    assert_includes jobs.keys, "image_excludes_docs", <<~MSG
      The image_excludes_docs job is gone from ci.yml. Without it, a docs regression is
      only caught by the release build on main -- after merge.
    MSG

    audit_build = jobs.dig("image_excludes_docs", "steps").any? do |step|
      step["run"].to_s.include?("--file Dockerfile.docs-audit")
    end
    assert audit_build, <<~MSG
      No step in image_excludes_docs builds Dockerfile.docs-audit, so the job passes
      without asserting anything.
    MSG

    assert_includes jobs.dig("all-checks-pass", "needs"), "image_excludes_docs", <<~MSG
      all-checks-pass no longer lists image_excludes_docs in `needs:`. It is the single
      required status check for branch protection, so a job missing from it can fail
      without blocking the merge.
    MSG
  end
end
