# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "yaml"

# An extension (app/extensions/<id>/, see Zimmer::Extension) only does anything in the
# container that runs it. Nothing in Dockerfile is selective about getting it there --
# the build stage does a blanket `COPY . .` and the final stage a
# `COPY --from=build /rails /rails` -- so the whole invariant rests on .dockerignore NOT
# excluding that path. An absence, in a file whose every other line is a presence, is the
# hardest kind of thing to notice going missing.
#
# It went missing. `/app/extensions/*/` stripped every extension directory out of the
# build context and the failure was completely silent: the app booted, ExtensionRegistry
# skipped the classes that no longer resolved, every seam fell back to native, and nobody
# had a signal. The seam stayed dead long enough for the only extension that ever shipped
# to be rewritten as a plain AppSetting column. That is tadasant/zimmer#91.
#
# scripts/assert-extensions-shipped.sh replaces that trust with a check, against a real
# filesystem rather than against the text of .dockerignore, from two places:
#
#   Dockerfile                    /rails in the final stage -- the published image
#                                 itself. Fails the build, so a bad image is never pushed.
#   Dockerfile.extensions-audit   the real build context, in busybox, from PR CI's
#                                 image_includes_extensions job -- the same signal,
#                                 before merge.
#
# These assertions cover the half of that a Docker daemon is not needed for: that the
# detector detects (including the exact shape the old .dockerignore rule produced, so it
# can never pass vacuously), that it does not fire on a tree that is fine, that the canary
# it keys on is where it says it is, and that both callers are still wired up. The
# Docker-side half is the CI job itself.
class ExtensionsShippedInImageTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts/assert-extensions-shipped.sh")
  DOCKERFILE = Rails.root.join("Dockerfile")
  AUDIT_DOCKERFILE = Rails.root.join("Dockerfile.extensions-audit")
  CI_WORKFLOW = Rails.root.join(".github/workflows/ci.yml")
  DOCKERIGNORE = Rails.root.join(".dockerignore")
  EXTENSIONS_ROOT = Rails.root.join("app/extensions")
  CANARY = EXTENSIONS_ROOT.join("image_canary/IMAGE_CANARY.md")

  # The exact invocation each caller must keep. Both are load-bearing: an image whose
  # build no longer runs the script is an image with no guardrail on it.
  IMAGE_ASSERTION = "RUN /rails/scripts/assert-extensions-shipped.sh --root /rails"
  CONTEXT_ASSERTION = "RUN /ctx/scripts/assert-extensions-shipped.sh --root /ctx"

  def detect(root)
    Open3.capture2e(SCRIPT.to_s, "--root", root.to_s)
  end

  # A tree shaped like the repository's: app/extensions/ with the canary one level down.
  def healthy_tree(dir)
    FileUtils.mkdir_p(File.join(dir, "app/extensions/image_canary"))
    File.write(File.join(dir, "app/extensions/image_canary/IMAGE_CANARY.md"), "canary\n")
    File.write(File.join(dir, "app/extensions/CLAUDE.md"), "notes\n")
    dir
  end

  # ---- The invariant in this repository -----------------------------------------------

  # The check keys on this file. If it moves or is deleted, every caller fails -- which is
  # the right failure, but this test names the cause instead of leaving three red builds
  # to be diagnosed from a shell script's error message.
  test "the canary the guardrail keys on is present in this repo" do
    assert_path_exists CANARY, <<~MSG
      scripts/assert-extensions-shipped.sh looks for app/extensions/image_canary/IMAGE_CANARY.md
      to prove a SUBDIRECTORY of app/extensions/ reached the image. It is gone, so the
      Dockerfile build and CI's image_includes_extensions job both fail. Restore it, or
      change the marker the script looks for in both places at once.
    MSG
  end

  # The canary has to be one level down, because the rule this guards against
  # (`/app/extensions/*/`) excluded subdirectories and left app/extensions/CLAUDE.md
  # sitting at the top of the tree throughout. A marker at the top proves nothing.
  test "the canary is a subdirectory of app extensions, not a file at its top" do
    assert_equal EXTENSIONS_ROOT.join("image_canary"), CANARY.dirname
  end

  # A .rb file here would be autoloaded (config/application.rb collapses app/extensions/*),
  # turning a build-time marker into something the running app has to care about.
  test "the canary directory contributes nothing to the autoloader" do
    rb = Dir.glob(CANARY.dirname.join("**/*.rb"))
    assert_empty rb, "app/extensions/image_canary/ must hold no Ruby; found: #{rb.inspect}"
  end

  # The point of the whole change: nothing in .dockerignore may take the tree back out.
  # This is the text-level check, which the script deliberately is not -- it is cheap, it
  # names the exact line to delete, and the outcome-based script behind it catches the
  # spellings a text check cannot enumerate.
  test "dockerignore carries no exclusion for the extension tree" do
    patterns = DOCKERIGNORE.read.lines.map { |l| l.sub(/#.*/, "").strip }.reject(&:empty?)

    offenders = patterns.select { |p| p.delete_prefix("!").include?("extensions") }
    assert_empty offenders, <<~MSG
      A .dockerignore pattern mentions the extension tree: #{offenders.inspect}

      Extensions are meant to ship in the image. `/app/extensions/*/` is the exact line
      that made the seam silently unreachable in production (tadasant/zimmer#91), and any
      pattern touching this path risks doing it again. Removability lives in the source
      tree -- delete app/extensions/<id>/ from the repo -- not in the build context.
    MSG
  end

  # ---- The detector detects ------------------------------------------------------------

  test "a healthy tree passes" do
    Dir.mktmpdir do |dir|
      output, status = detect(healthy_tree(dir))
      assert_predicate status, :success?, "Expected an intact tree to pass. Output:\n#{output}"
    end
  end

  # The real repository, so this suite can never pass vacuously against a tree it built
  # itself: whatever the script asserts, it asserts about what is actually here.
  test "this repository passes" do
    output, status = detect(Rails.root)
    assert_predicate status, :success?, "Expected the repo to pass its own guardrail. Output:\n#{output}"
  end

  # The regression itself, reproduced exactly: app/extensions/ present, CLAUDE.md present,
  # every subdirectory gone. This is what `/app/extensions/*/` produced, and what shipped.
  test "the tree the old dockerignore rule produced fails" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/extensions"))
      File.write(File.join(dir, "app/extensions/CLAUDE.md"), "notes\n")

      output, status = detect(dir)

      refute_predicate status, :success?, "Expected a subdirectory-less tree to fail. Output:\n#{output}"
      assert_match "IMAGE_CANARY.md is missing", output
    end
  end

  test "a missing extension tree fails" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app"))

      output, status = detect(dir)

      refute_predicate status, :success?, "Expected an absent app/extensions/ to fail. Output:\n#{output}"
      assert_match "app/extensions/ is not present", output
    end
  end

  # The narrower exclusion the canary alone would not catch: a pattern like
  # `app/extensions/**/*.rb` leaves every directory standing and empties the ones that
  # carry code, so the canary (which holds no Ruby) still arrives.
  test "an extension directory that arrived hollow fails" do
    Dir.mktmpdir do |dir|
      healthy_tree(dir)
      FileUtils.mkdir_p(File.join(dir, "app/extensions/pty_transport"))

      output, status = detect(dir)

      refute_predicate status, :success?, "Expected an empty extension directory to fail. Output:\n#{output}"
      assert_match "arrived empty", output
      assert_match "pty_transport", output
    end
  end

  # The same exclusion, one level down -- and the reason the scan is not depth-limited.
  # app/extensions/CLAUDE.md blesses a `lib/` driver script inside an extension, so that
  # is where `app/extensions/**/*.rb` empties a directory in the layout the repo actually
  # recommends. A scan capped at depth 1 sees pty_transport/ still holding lib/ and calls
  # the tree healthy.
  test "a hollow directory nested inside an extension fails" do
    Dir.mktmpdir do |dir|
      healthy_tree(dir)
      FileUtils.mkdir_p(File.join(dir, "app/extensions/pty_transport/lib"))
      File.write(File.join(dir, "app/extensions/pty_transport/pty_transport_extension.rb"), "# x\n")

      output, status = detect(dir)

      refute_predicate status, :success?, "Expected a nested empty directory to fail. Output:\n#{output}"
      assert_match "arrived empty", output
      assert_match "pty_transport/lib", output
    end
  end

  test "an extension directory carrying code passes" do
    Dir.mktmpdir do |dir|
      healthy_tree(dir)
      FileUtils.mkdir_p(File.join(dir, "app/extensions/pty_transport"))
      File.write(File.join(dir, "app/extensions/pty_transport/pty_transport_extension.rb"), "# x\n")

      output, status = detect(dir)

      assert_predicate status, :success?, "Expected a populated extension to pass. Output:\n#{output}"
    end
  end

  # Both Dockerfiles invoke the script directly (`RUN /rails/scripts/...`), not through an
  # interpreter, so the mode bit is part of the contract. Without this the failure is a
  # bare Errno::EACCES from every other test in the file, which names the symptom and not
  # the cause.
  test "the script is executable, since Docker runs it directly" do
    assert File.executable?(SCRIPT), "#{SCRIPT} must be executable; Dockerfile runs it directly."
  end

  # ---- Usage errors are not passes -----------------------------------------------------

  test "a missing or nonexistent root is a usage error, not a pass" do
    _, no_arg = Open3.capture2e(SCRIPT.to_s)
    assert_equal 2, no_arg.exitstatus, "Expected no --root to exit 2, not to scan something."

    _, missing_dir = Open3.capture2e(SCRIPT.to_s, "--root", "/nonexistent-tree")
    assert_equal 2, missing_dir.exitstatus, <<~MSG
      Expected a nonexistent --root to exit 2. Treating it as an empty tree would make a
      typo in either Dockerfile read as "extensions are fine here" forever -- and unlike
      the docs guardrail, whose absence-shaped invariant a typo happens to satisfy, this
      one would then be asserting the opposite of what it says.
    MSG
  end

  # A trailing slash on --root must not change the paths the script builds, or the
  # Dockerfile caller's spelling and the audit caller's would diverge on a whim.
  test "a trailing slash on root is tolerated" do
    Dir.mktmpdir do |dir|
      output, status = detect("#{healthy_tree(dir)}/")
      assert_predicate status, :success?, "Expected a trailing slash to be stripped. Output:\n#{output}"
    end
  end

  # ---- Both callers are still wired up -------------------------------------------------

  test "the published image build asserts the invariant against its own filesystem" do
    assert_includes File.read(DOCKERFILE), IMAGE_ASSERTION, <<~MSG
      Dockerfile no longer runs the extensions guardrail. This is the assertion that
      inspects the REAL published image, and the one that stops a bad image from being
      pushed at all -- it fails the build. Restore:

        #{IMAGE_ASSERTION}
    MSG
  end

  test "the build-context audit asserts the invariant" do
    assert_includes File.read(AUDIT_DOCKERFILE), CONTEXT_ASSERTION, <<~MSG
      Dockerfile.extensions-audit no longer runs the guardrail, so CI's
      image_includes_extensions job builds an image that checks nothing and passes. Restore:

        #{CONTEXT_ASSERTION}
    MSG
  end

  # A guardrail that reports OK when its own machinery is broken looks exactly like a
  # passing check, which is worse than no check. The empty-directory scan is the one step
  # that shells out, so a `find` that cannot run must exit 2 rather than fall through to
  # the "OK" at the bottom.
  test "a find that cannot run exits 2 rather than passing" do
    Dir.mktmpdir do |shim_dir|
      shim = File.join(shim_dir, "find")
      File.write(shim, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, shim)

      Dir.mktmpdir do |dir|
        env = { "PATH" => "#{shim_dir}:#{ENV['PATH']}" }
        _, status = Open3.capture2e(env, SCRIPT.to_s, "--root", healthy_tree(dir))

        assert_equal 2, status.exitstatus, <<~MSG
          Expected a broken `find` to exit 2. Exiting 0 would make a guardrail whose scan
          silently failed indistinguishable from one that found nothing wrong.
        MSG
      end
    end
  end

  test "CI runs the build-context audit and the aggregate gate requires it" do
    jobs = YAML.safe_load(File.read(CI_WORKFLOW)).fetch("jobs")

    assert_includes jobs.keys, "image_includes_extensions", <<~MSG
      The image_includes_extensions job is gone from ci.yml. Without it, an extension-tree
      regression is only caught by the release build on main -- after merge.
    MSG

    audit_build = jobs.dig("image_includes_extensions", "steps").any? do |step|
      step["run"].to_s.include?("--file Dockerfile.extensions-audit")
    end
    assert audit_build, <<~MSG
      No step in image_includes_extensions builds Dockerfile.extensions-audit, so the job
      passes without asserting anything.
    MSG

    assert_includes jobs.dig("all-checks-pass", "needs"), "image_includes_extensions", <<~MSG
      all-checks-pass no longer lists image_includes_extensions in `needs:`. It is the
      single required status check for branch protection, so a job missing from it can
      fail without blocking the merge.
    MSG
  end
end
