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
  # The sentinel `ensure_air_installed!` looks for: `.air-version-0.13.0`.
  AIR_VERSION_MARKER = /\.air-version-(\d+\.\d+\.\d+)/

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

  test "the .air-version marker baked into the image matches AIR_CLI_VERSION" do
    markers = File.read(DOCKERFILE_BASE).scan(AIR_VERSION_MARKER).flatten.uniq

    assert_equal [ AirPrepareService::AIR_CLI_VERSION ], markers,
      "Dockerfile.base touches #{markers.inspect} but ensure_air_installed! looks for " \
      ".air-version-#{AirPrepareService::AIR_CLI_VERSION}. A mismatch makes every fresh " \
      "container reinstall the AIR CLI on its first session."
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
