# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"

# Agent sessions all share ONE Postgres -- the `devdb` Kamal accessory -- because a
# session cannot start a database for itself (no root, no sudo, no Docker socket).
# Sharing a server means the database NAMES have to be per-clone, or two sessions
# that boot `bin/agent-dev` at the same time run each other's migrations.
#
# The mechanism is a single DATABASE_NAME env var read by config/database.yml. These
# assertions pin the two halves that are easy to get wrong:
#
#   1. Unset, every name is byte-for-byte what it was before the override existed.
#      Every laptop and CI run depends on that.
#   2. Set, ALL FOUR names move -- including the test pair. `db:prepare` in
#      development creates the test databases too, so an override that namespaced
#      only development would leave every session colliding on `zimmer_test`.
class DatabaseNameOverrideTest < ActiveSupport::TestCase
  DATABASE_YML = Rails.root.join("config/database.yml")

  # Postgres truncates identifiers past 63 bytes, silently, to something that may
  # collide with a different clone's truncation. bin/agent-dev caps what it sets at
  # 52 so the longest suffix built here (`_test_cable`) still fits.
  PG_IDENTIFIER_LIMIT = 63

  def config_with(database_name)
    previous = ENV["DATABASE_NAME"]
    if database_name.nil?
      ENV.delete("DATABASE_NAME")
    else
      ENV["DATABASE_NAME"] = database_name
    end
    YAML.safe_load(ERB.new(DATABASE_YML.read).result, aliases: true)
  ensure
    previous.nil? ? ENV.delete("DATABASE_NAME") : ENV["DATABASE_NAME"] = previous
  end

  test "unset DATABASE_NAME leaves the historical development and test names untouched" do
    config = config_with(nil)

    assert_equal "zimmer_development", config.dig("development", "primary", "database")
    assert_equal "zimmer_development_cable", config.dig("development", "cable", "database")
    assert_equal "zimmer_test", config.dig("test", "primary", "database")
    assert_equal "zimmer_test_cable", config.dig("test", "cable", "database")
  end

  test "DATABASE_NAME namespaces all four development and test databases" do
    config = config_with("zimmer_dev_clone_abc")

    assert_equal "zimmer_dev_clone_abc", config.dig("development", "primary", "database")
    assert_equal "zimmer_dev_clone_abc_cable", config.dig("development", "cable", "database")
    assert_equal "zimmer_dev_clone_abc_test", config.dig("test", "primary", "database")
    assert_equal "zimmer_dev_clone_abc_test_cable", config.dig("test", "cable", "database")
  end

  test "DATABASE_NAME does not reach the deployed environments" do
    config = config_with("zimmer_dev_clone_abc")

    assert_equal "zimmer_staging", config.dig("staging", "primary", "database")
    assert_equal "zimmer_staging_cable", config.dig("staging", "cable", "database")
    assert_equal "zimmer_production", config.dig("production", "primary", "database")
    assert_equal "zimmer_production_cable", config.dig("production", "cable", "database")
  end

  # The cap bin/agent-dev applies, asserted against the limit it exists to respect.
  test "a DATABASE_NAME at bin/agent-dev's cap still fits every suffix inside Postgres's identifier limit" do
    at_cap = "z" * 52
    config = config_with(at_cap)

    %w[development test].each do |env|
      %w[primary cable].each do |role|
        name = config.dig(env, role, "database")
        assert_operator name.bytesize, :<=, PG_IDENTIFIER_LIMIT,
          "#{env}/#{role} database name is #{name.bytesize} bytes, past Postgres's #{PG_IDENTIFIER_LIMIT}"
      end
    end
  end

  # The cap itself, read out of the script rather than restated here, so raising one
  # without the other fails instead of silently truncating clone databases.
  test "bin/agent-dev's cap matches the width these assertions assume" do
    script = Rails.root.join("bin/agent-dev").read
    declared = script[/^MAX_DATABASE_NAME=(\d+)/, 1]

    assert declared, "bin/agent-dev no longer declares MAX_DATABASE_NAME"
    assert_equal 52, declared.to_i,
      "bin/agent-dev caps derived database names at #{declared}, but these assertions assume 52"
  end

  # The cap is worth nothing if the truncation drops the part that makes one clone
  # different from another. Clone directories are `<repo>-<branch>-<timestamp>-<hex8>`
  # (GitCloneService), so the distinguishing bytes are at the END: two clones of one
  # repo and branch differ only in their tail. A head-truncating cap would hand them
  # the same database and let them run each other's migrations in silence.
  test "the derived name keeps the tail of the clone directory, where clones differ" do
    a = derived_name_for("zimmer-fix-agent-session-dev-boot-1786516772-f72d11bd")
    b = derived_name_for("zimmer-fix-agent-session-dev-boot-1786599999-aaaa1111")

    assert_equal 52, a.bytesize, "the sample should be long enough to exercise truncation"
    refute_equal a, b, "two clones of the same repo and branch derived the same database name"
    assert a.end_with?("f72d11bd"), "the clone's unique suffix was truncated away: #{a}"
    assert b.end_with?("aaaa1111"), "the clone's unique suffix was truncated away: #{b}"
  end

  private

  # Run the script's own derivation against a directory name, rather than a Ruby
  # restatement of it that could drift from the shell.
  #
  # The script resolves its repo root from its own path, so the copy has to live at
  # <basename>/bin/agent-dev for `basename "$PWD"` to see the name under test.
  def derived_name_for(basename)
    dir = Dir.mktmpdir
    root = File.join(dir, basename)
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.cp(Rails.root.join("bin/agent-dev"), File.join(root, "bin/agent-dev"))

    # Clear DATABASE_NAME for the child or it takes the override branch and reports
    # back whatever the test runner happens to be connected to, never deriving anything.
    out, status = Open3.capture2e(
      { "DATABASE_NAME" => nil },
      File.join(root, "bin/agent-dev"), "--print-database-name"
    )
    assert_predicate status, :success?, "bin/agent-dev --print-database-name failed: #{out}"
    out.strip
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end
end
