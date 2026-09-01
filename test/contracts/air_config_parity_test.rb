# frozen_string_literal: true

require "test_helper"
require "json"

# Two pairs of files in this repo are kept in sync by hand, with nothing checking
# that they still agree. Both drift silently and both fail late.
#
# 1. The AIR CLI version is pinned twice: `Dockerfile.base` bakes the packages
#    into the image and touches a `.air-version-<v>` marker;
#    `AirPrepareService::AIR_CLI_VERSION` is what the app looks for. They are the
#    same string today by convention only. Bump one and not the other and
#    `ensure_air_installed!` misses the marker on every boot — so the first
#    session on a fresh container replaces the baked-in install and re-downloads
#    the CLI from npm on the session's launch path, or (the other direction)
#    trusts a marker for a version the image never installed.
#
# 2. `air.json` (dev/test) and `air.production.json` (in-image) declare the same
#    catalog and are mirrored by hand. Their only intended difference is
#    `description`. A wiring change applied to one and not the other means
#    production resolves a different catalog than every test in this suite.
#
# Tracked in https://github.com/tadasant/zimmer/issues/68.
class AirConfigParityTest < ActiveSupport::TestCase
  DOCKERFILE_BASE = Rails.root.join("Dockerfile.base")
  AIR_JSON = Rails.root.join("air.json")
  AIR_PRODUCTION_JSON = Rails.root.join("air.production.json")

  # `@pulsemcp/air-cli@0.13.0`, `@pulsemcp/air-adapter-claude@0.13.0`, …
  AIR_PACKAGE_PIN = %r{@pulsemcp/(air-[a-z-]+)@(\d+\.\d+\.\d+)}
  # The sentinel `ensure_air_installed!` looks for, e.g.
  # `.air-version-0.13.0-715a27ec` — version plus a digest of the package SET.
  AIR_VERSION_MARKER = /\.air-version-[\w.-]+/

  # The one key the two catalog configs are allowed to differ on.
  PERMITTED_DIVERGENCE = "description"

  test "every AIR package pinned in Dockerfile.base is at AirPrepareService::AIR_CLI_VERSION" do
    dockerfile = File.read(DOCKERFILE_BASE)
    pins = dockerfile.scan(AIR_PACKAGE_PIN)

    assert_operator pins.size, :>=, 5,
      "expected Dockerfile.base to pin the AIR CLI and its adapters; found #{pins.size} pin(s)"

    pins.each do |package, version|
      assert_equal AirPrepareService::AIR_CLI_VERSION, version,
        "Dockerfile.base pins @pulsemcp/#{package}@#{version} but " \
        "AirPrepareService::AIR_CLI_VERSION is #{AirPrepareService::AIR_CLI_VERSION}. " \
        "Bump both together."
    end
  end

  test "the .air-version marker baked into the image matches the one ensure_air_installed! looks for" do
    markers = File.read(DOCKERFILE_BASE).scan(AIR_VERSION_MARKER).uniq

    assert_equal [ AirPrepareService.air_marker_filename ], markers,
      "Dockerfile.base touches #{markers.inspect} but ensure_air_installed! looks for " \
      "#{AirPrepareService.air_marker_filename.inspect}. A mismatch makes every fresh " \
      "container reinstall the AIR CLI on its first session."
  end

  # The marker is keyed on a digest of the package set precisely so that CHANGING
  # THE LIST invalidates it. A version-only key cannot see a new adapter added at
  # the same version, so every host already holding the old marker would skip the
  # install and the first session on the new runtime would die with an
  # unknown-adapter error — with no in-app way to fix it.
  test "changing the AIR package set changes the install marker" do
    baseline = AirPrepareService.air_marker_filename

    with_packages(AirPrepareService::AIR_PACKAGES + [ "@pulsemcp/air-adapter-invented@#{AirPrepareService::AIR_CLI_VERSION}" ]) do
      assert_not_equal baseline, AirPrepareService.air_marker_filename,
        "adding a package must change the marker, or the new package never installs " \
        "on a host that already holds the old marker"
    end

    assert_equal baseline, AirPrepareService.air_marker_filename,
      "the marker must be restored once the package set is"
  end

  test "Dockerfile.base installs exactly the packages AirPrepareService installs" do
    dockerfile = File.read(DOCKERFILE_BASE)

    AirPrepareService::AIR_PACKAGES.each do |package|
      assert_includes dockerfile, package,
        "Dockerfile.base must pre-install #{package} — AirPrepareService installs it, and a " \
        "host that skips it fails on the first session that needs it"
    end
  end

  # Swap AIR_PACKAGES for the duration of a block. A frozen constant on a module,
  # so remove_const/const_set is the only way — the same technique the Codex home
  # tests use for their boot-snapshotted constants.
  def with_packages(packages)
    original = AirPrepareService::AIR_PACKAGES
    AirPrepareService.send(:remove_const, :AIR_PACKAGES)
    AirPrepareService.const_set(:AIR_PACKAGES, packages.freeze)
    yield
  ensure
    AirPrepareService.send(:remove_const, :AIR_PACKAGES)
    AirPrepareService.const_set(:AIR_PACKAGES, original)
  end

  test "air.json and air.production.json declare the same catalog" do
    dev = JSON.parse(File.read(AIR_JSON))
    prod = JSON.parse(File.read(AIR_PRODUCTION_JSON))

    assert_equal dev.except(PERMITTED_DIVERGENCE), prod.except(PERMITTED_DIVERGENCE),
      "air.json and air.production.json diverge outside #{PERMITTED_DIVERGENCE.inspect}. " \
      "They are mirrored by hand — apply the change to both."
  end

  test "both catalog configs carry their own description" do
    # The exemption above only holds if each file really does describe itself;
    # otherwise a missing key would pass the parity check by accident.
    [ AIR_JSON, AIR_PRODUCTION_JSON ].each do |path|
      description = JSON.parse(File.read(path))[PERMITTED_DIVERGENCE]
      assert description.present?, "#{path.basename} has no #{PERMITTED_DIVERGENCE}"
    end
  end
end
