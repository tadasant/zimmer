# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# CI wiring, and the behavioural spec, for MigrationVersionGuard — the guard
# behind the 2026-09-05 duplicate-version outage. The guard itself is Rails-free
# and the `lint` job runs it directly, seconds into CI; this file is the second
# place it runs, so a contributor who only runs `bin/rails test` still sees it.
class MigrationVersionTest < ActiveSupport::TestCase
  test "no two migrations claim the same version or class name" do
    collisions = MigrationVersionGuard.collisions

    assert_empty collisions, MigrationVersionGuard.report(collisions)
  end

  # The real incident, rebuilt: 20260905180000 was written by hand into two
  # separate branches, and neither one could see the other. A guard that has
  # never been seen to fail is not a guard, and `main` is fixed, so this is the
  # only place the collision still exists.
  test "the two migrations that both claimed 20260905180000 are caught" do
    collisions = in_migration_dir(
      "20260905180000_add_armed_at_to_trigger_conditions.rb",
      "20260905180000_add_replaces_session_index_to_sessions.rb",
      "20260905190000_add_something_else.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_equal 1, collisions.size
    collision = collisions.sole

    assert_equal :version, collision.kind
    assert_equal 20260905180000, collision.value
    assert_equal [ "20260905180000_add_armed_at_to_trigger_conditions.rb",
      "20260905180000_add_replaces_session_index_to_sessions.rb" ], collision.paths

    report = MigrationVersionGuard.report(collisions)
    assert_includes report, "20260905180000"
    assert_includes report, "db/migrate/20260905180000_add_armed_at_to_trigger_conditions.rb"
    assert_includes report, "db/migrate/20260905180000_add_replaces_session_index_to_sessions.rb"
    assert_includes report, "DuplicateMigrationVersionError"
  end

  # Rails refuses a repeated class name at the same point in boot, for the same
  # reason, so the guard reports it in the same breath.
  test "two migrations with the same class name at different versions are caught" do
    collisions = in_migration_dir(
      "20260101000000_add_widget_to_sessions.rb",
      "20260202000000_add_widget_to_sessions.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_equal [ :class_name ], collisions.map(&:kind)
    assert_equal "AddWidgetToSessions", collisions.sole.value
    assert_includes MigrationVersionGuard.report(collisions), "DuplicateMigrationNameError"
  end

  # Rails groups on `name.camelize`, so the underscore is not what makes these
  # two distinct. Comparing the snake_cased forms would call this pair fine and
  # then watch Rails raise on it.
  test "class names that differ only by an underscore are the same name to Rails" do
    collisions = in_migration_dir(
      "20260101000000_add_widget_2.rb",
      "20260202000000_add_widget2.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_equal [ :class_name ], collisions.map(&:kind)
    assert_equal "AddWidget2", collisions.sole.value
  end

  test "a directory of distinct migrations is clean" do
    collisions = in_migration_dir(
      "20260101000000_add_widget_to_sessions.rb",
      "20260202000000_add_gadget_to_sessions.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_empty collisions
    assert_equal "", MigrationVersionGuard.report(collisions)
  end

  # Rails' glob is `[0-9]*_*.rb`, so anything else in db/migrate is not a
  # migration and has no version to collide with. Reporting it would be noise.
  test "files that are not migrations are ignored" do
    migrations = in_migration_dir(
      "20260101000000_add_widget_to_sessions.rb",
      ".keep",
      "README.md",
      "add_widget_to_sessions.rb",
      "20260101000000_add_widget_to_sessions.rb.bak"
    ) { |dir| MigrationVersionGuard.migrations(dir) }

    assert_equal [ "20260101000000_add_widget_to_sessions.rb" ], migrations.map(&:relative_path)
  end

  # The guard cannot ask Active Record what a migration filename looks like —
  # it has to run when Rails does not boot — so it carries a copy of the
  # regexp. A copy that drifts is a guard that skips the file Rails trips on.
  test "the copied filename regexp is still Active Record's" do
    assert_equal ActiveRecord::Migration::MigrationFilenameRegexp.source,
      MigrationVersionGuard::FILENAME.source,
      "Active Record changed MigrationFilenameRegexp — update the copy in " \
      "test/support/migration_version_guard.rb to match."
  end

  # Rails' regexp is [0-9]+, not \d{14}, and a version it cannot read is a
  # version it cannot collide — so a hand-typed short timestamp is exactly the
  # kind of mistake a stricter guard would step over.
  test "a version that is not fourteen digits still collides" do
    collisions = in_migration_dir(
      "2026090518000_add_widget_to_sessions.rb",
      "2026090518000_add_gadget_to_sessions.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_equal [ :version ], collisions.map(&:kind)
    assert_equal 2026090518000, collisions.sole.value
  end

  # Rails compares `version.to_i`, so a leading zero changes the filename and
  # not the version.
  test "leading zeros do not make a version distinct" do
    collisions = in_migration_dir(
      "020260101000000_add_doodad_to_sessions.rb",
      "20260101000000_add_thingummy_to_sessions.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_equal [ 20260101000000 ], collisions.map(&:value)
  end

  # `Migrator#migration_files` globs `**/[0-9]*_*.rb`, so a subdirectory is not
  # a hiding place. The report names the path, not just the basename.
  test "a migration in a subdirectory is found, and reported by path" do
    collisions = in_migration_dir(
      "nested/20260101000000_add_widget_to_sessions.rb",
      "20260101000000_add_gadget_to_sessions.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_equal [ 20260101000000 ], collisions.map(&:value)
    assert_includes MigrationVersionGuard.report(collisions),
      "db/migrate/nested/20260101000000_add_widget_to_sessions.rb"
  end

  # `..._add_widget_to_sessions.postgresql.rb` is an adapter-scoped migration.
  # Rails strips the scope before comparing names, so this pair is a name
  # collision — and a regexp with no scope group would not see the file at all.
  test "an adapter-scoped filename is read the way Rails reads it" do
    collisions = in_migration_dir(
      "20260101000000_add_widget_to_sessions.postgresql.rb",
      "20260202000000_add_widget_to_sessions.rb"
    ) { |dir| MigrationVersionGuard.collisions(dir) }

    assert_equal [ :class_name ], collisions.map(&:kind),
      "the adapter scope is not part of the name Rails groups on"
  end

  # The whole point: the failure it catches is a Rails boot failure, so the
  # check has to answer when Rails cannot boot. The subprocess asserts that for
  # itself — merely exiting 0 would stay true if the guard quietly required
  # Rails, since the parent runs under bundler and the require would succeed.
  test "the guard loads neither Rails nor Active Record" do
    probe = 'abort("Rails is loaded") if defined?(Rails); ' \
      'abort("Active Record is loaded") if $LOADED_FEATURES.grep(/active_record/).any?; ' \
      "print MigrationVersionGuard.report"

    output = Dir.chdir(Rails.root) do
      `ruby -r./test/support/migration_version_guard -e '#{probe}' 2>&1`
    end

    assert_predicate $?, :success?, output
    assert_equal "", output
  end

  # The guard is only as good as the set of files it looks at, and every bug
  # found in review so far was a file it silently skipped rather than a
  # comparison it got wrong. This is the canary for that class.
  test "every .rb file in db/migrate is a file the guard reads" do
    found = MigrationVersionGuard.migrations

    assert_not_empty found, "no migrations found in db/migrate"

    skipped = Dir.children(MigrationVersionGuard::MIGRATION_DIR).grep(/\.rb\z/) -
      found.map(&:relative_path)

    assert_empty skipped,
      "the guard does not recognise these, so it cannot see a collision in them: " \
      "#{skipped.join(", ")}"
  end

  # `test-unit` is minutes into CI and needs Postgres to get there; the whole
  # value of a Rails-free guard is that `lint` answers in seconds without one.
  # Losing that step would leave this file passing and the guard useless.
  test "the lint job runs the guard" do
    lint = YAML.load_file(Rails.root.join(".github/workflows/ci.yml")).dig("jobs", "lint", "steps")

    assert lint.any? { |step| step["run"].to_s.include?("MigrationVersionGuard.report") },
      "the `lint` job in .github/workflows/ci.yml no longer runs MigrationVersionGuard"
  end

  private

  # The guard reads filenames, so a fixture is a directory of empty files —
  # nothing parses the bodies. Paths may name a subdirectory, because Rails
  # descends into them.
  def in_migration_dir(*relative_paths)
    Dir.mktmpdir do |dir|
      relative_paths.each do |relative_path|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.touch(path)
      end

      yield dir
    end
  end
end
