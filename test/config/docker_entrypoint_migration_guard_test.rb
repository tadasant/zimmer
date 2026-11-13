# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# bin/docker-entrypoint refuses to boot an image whose migrations collide.
#
# `db:prepare` cannot be relied on for that: it only builds the Migrator that
# raises DuplicateMigrationVersionError when something is pending, so against a
# database that already has the shared version it skips the second migration in
# silence. That is how #1484's table never reached production on 2026-11-13
# (zimmer#1500). A container that exits before `/up` answers is one Kamal's
# health gate never cuts over to.
#
# These run the real entrypoint, unprivileged, with MIGRATION_VERSION_GUARD_DIR
# pointing the guard at a directory of fixture filenames. The command it is
# asked to exec is `echo booted`, so "booted" in the output means it got past
# the guard.
class DockerEntrypointMigrationGuardTest < ActiveSupport::TestCase
  ENTRYPOINT = Rails.root.join("bin/docker-entrypoint").to_s

  test "an image with two migrations on one version refuses to start" do
    output, status = run_entrypoint(
      "20261111120000_add_author_to_live_conversation_turns.rb",
      "20261111120000_create_mcp_event_webhook_subscriptions.rb"
    )

    assert_equal 1, status.exitstatus, output
    assert_not_includes output, "booted"
    assert_includes output, "Refusing to start"
    assert_includes output, "db/migrate/20261111120000_create_mcp_event_webhook_subscriptions.rb"
  end

  test "an image with distinct migrations boots" do
    output, status = run_entrypoint(
      "20261111120000_add_author_to_live_conversation_turns.rb",
      "20261113070000_create_mcp_event_webhook_subscriptions.rb"
    )

    assert_predicate status, :success?, output
    assert_includes output, "booted"
    assert_not_includes output, "Refusing to start"
  end

  # The image this ships in is the one under test: its own migrations must pass.
  test "the guard passes on this tree's own migrations" do
    output, status = Open3.capture2e("ruby", Rails.root.join("bin/migration-version-guard").to_s)

    assert_predicate status, :success?, output
  end

  private

  # Stubs `id` so the entrypoint takes the non-root path whatever uid runs the
  # suite, and `claude` so its background `claude update` is a no-op. It runs
  # from an empty directory, so the playwright install it would background is
  # skipped too. LD_PRELOAD is set (empty) so it does not go looking for jemalloc.
  def run_entrypoint(*migrations)
    Dir.mktmpdir do |dir|
      migrate = File.join(dir, "migrate")
      stubs = File.join(dir, "stubs")
      cwd = File.join(dir, "cwd")
      FileUtils.mkdir_p([ migrate, stubs, cwd ])
      migrations.each { |name| FileUtils.touch(File.join(migrate, name)) }

      write_stub stubs, "id", 'if [ "$1" = "-u" ]; then echo 1000; else exit 0; fi'
      write_stub stubs, "claude", "exit 0"

      env = {
        "PATH" => "#{stubs}:#{ENV.fetch("PATH")}",
        "MIGRATION_VERSION_GUARD_DIR" => migrate,
        "ZIMMER_BOOT_TASKS_MARKER" => File.join(dir, "boot-tasks-ready"),
        "LD_PRELOAD" => ""
      }
      Open3.capture2e(env, ENTRYPOINT, "echo", "booted", chdir: cwd)
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    File.chmod(0o755, path)
  end
end
