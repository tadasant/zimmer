# frozen_string_literal: true

require "test_helper"

# PiExtensions is the registry of Pi extensions Zimmer loads with `pi -e`. Pi has
# no MCP, hooks, or plugins of its own, so this list is the whole of Zimmer's
# answer to that gap.
class PiExtensionsTest < ActiveSupport::TestCase
  setup do
    @fs = MockFileSystemAdapter.new
  end

  test "declares the three extensions Zimmer needs Pi to load" do
    assert_equal(
      [ "pi-mcp-adapter", "@tadasant/pi-hooks", "@tadasant/pi-plugins" ],
      PiExtensions.all.map(&:package)
    )
    assert PiExtensions.all.all? { |ext| ext.version.present? }, "every entry must be pinned"
  end

  # `npm install` is all-or-nothing, so naming an unpublished package in the
  # Dockerfile would 404 and fail the whole base image. All three are published,
  # so all three go in; the flag stays available for the next one that is not.
  test "every declared extension is installable into the image" do
    assert_equal PiExtensions.all.map(&:package), PiExtensions.installable.map(&:package)
    assert_empty PiExtensions.all.select(&:pending_publish?)
  end

  # The Dockerfile's install line and this registry must not drift apart.
  test "the Dockerfile installs exactly the installable extensions at their pinned versions" do
    dockerfile = Rails.root.join("Dockerfile.base").read

    PiExtensions.installable.each do |ext|
      assert_includes dockerfile, "#{ext.package}@#{ext.version}",
        "Dockerfile.base must install #{ext}"
    end

    PiExtensions.all.select(&:pending_publish?).each do |ext|
      assert_not_includes dockerfile, "#{ext.package}@#{ext.version}",
        "Dockerfile.base must NOT install the unpublished #{ext} — npm install is all-or-nothing"
    end
  end

  # `npm install` succeeds as long as the tarball unpacked, so the image's only
  # proof that an extension is actually loadable is the `test -f` on its
  # entrypoint. That check is worth nothing if it names a different path than
  # the one #resolved_paths hands to `pi -e`: the build goes green and every Pi
  # session runs with the extension silently dropped.
  #
  # The prefix is the literal `/opt/pi-extensions` rather than INSTALL_DIR on
  # purpose. INSTALL_DIR is what THIS process reads, and PI_EXTENSIONS_DIR can
  # redirect it to somewhere a CI runner can write; the image's prefix is fixed
  # by the Dockerfile's own `npm install --prefix`. Only `entrypoint` is shared
  # between the two, so it is the only part worth asserting against.
  test "the Dockerfile smoke-checks the entrypoint the registry declares" do
    dockerfile = Rails.root.join("Dockerfile.base").read

    PiExtensions.installable.each do |ext|
      assert_includes dockerfile, "test -f /opt/pi-extensions/node_modules/#{ext.entrypoint}",
        "Dockerfile.base must assert #{ext}'s real entrypoint after installing it"
    end
  end

  # Pi loads TypeScript extension sources directly. A `dist/index.js` here is
  # the signature of the entrypoint having been guessed rather than read out of
  # the package's `pi.extensions` manifest field, and none of these packages
  # ships one.
  test "no entrypoint points at a compiled dist bundle" do
    PiExtensions.all.each do |ext|
      assert_not_includes ext.entrypoint, "dist/",
        "#{ext}'s entrypoint must come from its package.json `pi.extensions` field"
    end
  end

  test "resolved_paths returns only entrypoints present on disk, in registry order" do
    present = PiExtensions.all.first
    @fs.write(present.path, "// extension")

    assert_equal [ present.path ], PiExtensions.resolved_paths(file_system: @fs)
  end

  # Load order matters: pi-plugins activates artifacts the other two implement.
  test "resolved_paths preserves registry order when everything is present" do
    PiExtensions.all.each { |ext| @fs.write(ext.path, "// extension") }

    assert_equal PiExtensions.all.map(&:path), PiExtensions.resolved_paths(file_system: @fs)
  end

  test "resolved_paths is empty rather than raising when nothing is installed" do
    assert_equal [], PiExtensions.resolved_paths(file_system: @fs)
  end

  test "missing reports every declared extension that is not on disk" do
    assert_equal PiExtensions.all.map(&:package), PiExtensions.missing(file_system: @fs).map(&:package)

    PiExtensions.all.each { |ext| @fs.write(ext.path, "// extension") }
    assert_equal [], PiExtensions.missing(file_system: @fs)
  end

  # An absent pending_publish entry is expected; an absent published one means
  # the image build did not do what the registry says it does.
  test "the status summary distinguishes awaiting-publish from missing-from-image" do
    published, pending = PiExtensions.all.partition { |ext| !ext.pending_publish? }
    pending.each { |ext| @fs.write(ext.path, "// extension") }
    published.drop(1).each { |ext| @fs.write(ext.path, "// extension") }

    summary = PiExtensions.status_summary(file_system: @fs)
    assert_includes summary, "MISSING FROM IMAGE"
    assert_includes summary, published.first.package
    assert_not_includes summary, "awaiting npm publish"
  end

  # No entry carries the flag today, so this exercises the branch against a
  # synthetic one rather than deleting the reporting it guards.
  test "the status summary names a package that is only awaiting publication" do
    pending = PiExtensions::Extension.new(
      package: "@example/not-yet", version: "9.9.9",
      entrypoint: File.join("@example", "not-yet", "extensions", "x.ts"),
      purpose: "test double", pending_publish: true
    )
    PiExtensions.stub(:all, PiExtensions.all + [ pending ]) do
      PiExtensions.installable.each { |ext| @fs.write(ext.path, "// extension") }

      summary = PiExtensions.status_summary(file_system: @fs)
      assert_includes summary, "awaiting npm publish"
      assert_includes summary, "@example/not-yet"
      assert_not_includes summary, "MISSING FROM IMAGE"
    end
  end

  test "the status summary is a clean all-loaded line once everything is present" do
    PiExtensions.all.each { |ext| @fs.write(ext.path, "// extension") }

    assert_equal "all 3 Pi extensions loaded", PiExtensions.status_summary(file_system: @fs)
  end
end
