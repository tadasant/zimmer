# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Proves the drift check actually fails when it should.
#
# A guard whose failure path has never run is not a guard. These cases drive the
# script against a local directory standing in for upstream
# (OPEN_TRANSCRIPTS_SOURCE_DIR) so the whole comparison and its exit codes are
# exercised with no network: CI must not depend on GitHub being reachable, and a
# GitHub outage must not read as "upstream changed".
class CheckOpenTranscriptsDriftTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "check_open_transcripts_drift.rb")
  VENDOR_DIR = Rails.root.join("vendor", "open_transcripts")

  EXIT_OK = 0
  EXIT_DRIFT = 1
  EXIT_UNAVAILABLE = 2

  def manifest
    @manifest ||= JSON.parse(File.read(VENDOR_DIR.join("UPSTREAM.json")))
  end

  # Materialize the current snapshot into a directory laid out with the upstream
  # paths, so the script sees "upstream" as byte-identical to the snapshot.
  def build_fake_upstream(dir)
    manifest["files"].each do |entry|
      target = File.join(dir, entry["upstream"])
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(VENDOR_DIR.join("upstream", entry["local"]), target)
    end
  end

  def run_check(source_dir:, manifest_path: nil)
    env = { "OPEN_TRANSCRIPTS_SOURCE_DIR" => source_dir }
    env["OPEN_TRANSCRIPTS_MANIFEST"] = manifest_path if manifest_path
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT.to_s)
    [ status.exitstatus, stdout + stderr ]
  end

  test "passes when upstream matches the vendored snapshot" do
    Dir.mktmpdir do |dir|
      build_fake_upstream(dir)

      code, output = run_check(source_dir: dir)

      assert_equal EXIT_OK, code, output
      assert_match(/No drift/, output)
    end
  end

  test "fails loudly when an upstream file has changed" do
    Dir.mktmpdir do |dir|
      build_fake_upstream(dir)
      drifted = manifest["files"].first
      File.write(File.join(dir, drifted["upstream"]), "# upstream moved on without us\n", mode: "a")

      code, output = run_check(source_dir: dir)

      assert_equal EXIT_DRIFT, code, output
      assert_match(/DRIFT\s+#{Regexp.escape(drifted['local'])}/, output)
      assert_match(/has drifted from/, output)
      assert_match(/vendor\/open_transcripts\/README\.md/, output)
    end
  end

  test "fails when a tracked file no longer exists upstream" do
    Dir.mktmpdir do |dir|
      build_fake_upstream(dir)
      removed = manifest["files"].last
      FileUtils.rm(File.join(dir, removed["upstream"]))

      code, output = run_check(source_dir: dir)

      assert_equal EXIT_DRIFT, code, output
      assert_match(/GONE\s+#{Regexp.escape(removed['local'])}/, output)
    end
  end

  test "reports an unreadable manifest as unavailable, not as drift" do
    Dir.mktmpdir do |dir|
      build_fake_upstream(dir)

      code, output = run_check(source_dir: dir, manifest_path: File.join(dir, "not-a-manifest.json"))

      assert_equal EXIT_UNAVAILABLE, code, output
      assert_match(/could not run/, output)
    end
  end
end
