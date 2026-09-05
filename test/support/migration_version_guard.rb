# frozen_string_literal: true

# Finds two migrations that claim the same version, or the same class name,
# before Rails does.
#
# Rails resolves both at boot, not at migrate time: `ActiveRecord::Migrator`
# raises DuplicateMigrationVersionError (and DuplicateMigrationNameError) while
# building the migration list, which `maintain_test_schema!` walks on the way
# into *every* test run. So the failure is not "one migration misbehaves" — it
# is the whole suite dying before a single test executes, and the same
# exception surfacing in production runtime.
#
# That is exactly what happened on 2026-09-05: two PRs each hand-wrote a
# migration numbered 20260905180000 (#1005 added it to trigger_conditions,
# #1008 to sessions). Each branch was green on its own; the collision existed
# only on `main`, once both had merged. `test-unit` and `test-system` then died
# inside maintain_test_schema! on every commit pushed to main until the second
# migration was renumbered (26e77b7), and the same error reached production
# (GlitchTip #86).
#
# Nothing about that needs a database to detect: two filenames in a directory
# start with the same 14 digits. Deliberately Rails-free for that reason — the
# failure it guards against IS a Rails boot failure, so a check that had to
# boot Rails would be silent in the case that matters most. MigrationVersionTest
# is its wiring into `bin/rails test`, the `lint` job runs it directly, and
#
#   bundle exec ruby -r./test/support/migration_version_guard \
#     -e 'puts MigrationVersionGuard.report'
#
# is the same check by hand.
class MigrationVersionGuard
  MIGRATION_DIR = File.expand_path("../../db/migrate", __dir__)

  # Rails' own shape for a migration filename: 14 digits, an underscore, then
  # the snake_cased class name. `ActiveRecord::Migration.valid_version_format?`
  # would say the same thing, and requiring it would defeat the point.
  FILENAME = /\A(\d{14})_([_a-z0-9]*)\.rb\z/

  # One migration file on disk. `name` is the snake_cased class name, which is
  # the second thing Rails refuses to see twice.
  Migration = Struct.new(:basename, :version, :name, keyword_init: true)

  # A version or a name claimed by more than one file. `kind` is what Rails
  # would have called it.
  Collision = Struct.new(:kind, :value, :basenames, keyword_init: true)

  class << self
    # Every parseable migration in `dir`, oldest first. A file whose name does
    # not match FILENAME is not a migration Rails would load, so it is skipped
    # rather than reported — `.keep`, an editor's backup, a stray README.
    def migrations(dir = MIGRATION_DIR)
      Dir.children(dir).sort.filter_map do |basename|
        match = FILENAME.match(basename)
        next unless match

        Migration.new(basename: basename, version: match[1], name: match[2])
      end
    end

    # Both collisions Rails raises on, versions first because that is the one
    # that has actually shipped here.
    def collisions(dir = MIGRATION_DIR)
      found = migrations(dir)

      duplicates(found, :version) + duplicates(found, :name)
    end

    # What a contributor reads when the guard fails. Empty string when clean, so
    # it doubles as the standalone command's output.
    def report(collisions = self.collisions)
      collisions.map { |collision| collision_message(collision) }.join("\n")
    end

    private

    def duplicates(found, attribute)
      found.group_by(&attribute)
        .select { |_value, group| group.size > 1 }
        .map do |value, group|
          Collision.new(kind: attribute, value: value, basenames: group.map(&:basename))
        end
    end

    def collision_message(collision)
      <<~MESSAGE
        Two migrations share the #{collision.kind} #{collision.value}:
        #{collision.basenames.map { |basename| "  db/migrate/#{basename}" }.join("\n")}

        Rails builds its migration list at boot and raises
        ActiveRecord::#{collision.kind == :version ? "DuplicateMigrationVersionError" : "DuplicateMigrationNameError"}
        rather than picking one. `maintain_test_schema!` walks that list, so this
        does not fail a test — it kills the whole suite before any test runs, and
        it reaches production runtime the same way (zimmer#1005 / #1008, and
        GlitchTip #86).

        Renumber the newer migration to a timestamp nothing else has claimed, and
        re-dump db/schema.rb so its `version:` matches the newest migration:

          RAILS_ENV=test bin/rails db:drop db:create db:migrate

        Generating migrations with `bin/rails generate migration` instead of
        hand-writing the timestamp avoids this within a branch. It does not avoid
        it across branches: two branches that each pick a timestamp collide only
        once both have merged.
      MESSAGE
    end
  end
end
