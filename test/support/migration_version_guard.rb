# frozen_string_literal: true

# Finds two migrations that claim the same version, or the same class name,
# before Rails does.
#
# Rails resolves both at boot, not at migrate time: `ActiveRecord::Migrator`
# raises DuplicateMigrationVersionError (and DuplicateMigrationNameError) while
# building the migration list, which `maintain_test_schema!` walks on the way
# into *every* test run. So the failure is not "one migration misbehaves" — it
# is the whole suite dying before a single test executes.
#
# That is exactly what happened on 2026-09-05: two PRs each hand-wrote a
# migration numbered 20260905180000 (#1005 added it to trigger_conditions,
# #1008 to sessions). Each branch was green on its own; the collision existed
# only on `main`, once both had merged. `test-unit` and `test-system` then died
# inside maintain_test_schema! on every commit pushed to main until the second
# migration was renumbered (26e77b7), so for that window no commit on main was
# provably green.
#
# Nothing about that needs a database to detect: two filenames in a directory
# lead with the same version. Deliberately Rails-free for that reason — the
# failure it guards against IS a Rails boot failure, so a check that had to
# boot Rails would be silent in the case that matters most. MigrationVersionTest
# is its wiring into `bin/rails test`, the `lint` job runs it directly, and
#
#   bundle exec ruby -r./test/support/migration_version_guard \
#     -e 'puts MigrationVersionGuard.report'
#
# is the same check by hand.
#
# Two more callers lean on it being Rails-free. bin/migration-version-guard runs
# it from bin/docker-entrypoint, so an image whose migrations collide refuses to
# boot: `db:prepare` alone would silently skip one of them against a database
# that already has the version (zimmer#1500). And
# .github/scripts/migration-versions-vs-main.rb runs `merge_collisions` to check
# a PR against `main` as it is now, not as it was at the PR's last push.
class MigrationVersionGuard
  MIGRATION_DIR = File.expand_path("../../db/migrate", __dir__)

  # Copied from ActiveRecord::Migration::MigrationFilenameRegexp, because
  # matching Rails exactly is the whole job — a stricter pattern would skip a
  # file Rails does load and miss the collision. Note it is `[0-9]+`, not
  # `\d{14}`: a hand-typed 13-digit version is still a migration to Rails. The
  # optional third group is the adapter scope in `..._create_foo.postgresql.rb`,
  # which is part of neither the version nor the name.
  #
  # Requiring the constant from Active Record would defeat the point, so the
  # copy is deliberate; `migration_version_test.rb` asserts the two still agree.
  FILENAME = /\A([0-9]+)_([_a-z0-9]*)\.?([_a-z0-9]*)?\.rb\z/

  # Also Rails': `Migrator#migration_files` globs `**/[0-9]*_*.rb`, so a
  # migration in a subdirectory of db/migrate counts.
  GLOB = "**/[0-9]*_*.rb"

  # One migration file on disk, reduced to the two things Rails compares.
  # `version` is an Integer because Rails compares it as one —
  # `0020260905180000_x.rb` and `20260905180000_x.rb` are the same version to
  # it. `class_name` is camelized for the same reason: Rails groups on
  # `name.camelize`, so `add_widget_2` and `add_widget2` are one name to it and
  # a guard that compared the snake_cased forms would let that pair through.
  Migration = Struct.new(:relative_path, :version, :class_name, keyword_init: true)

  # A version or a name claimed by more than one file. `kind` is what Rails
  # would have called it.
  Collision = Struct.new(:kind, :value, :paths, keyword_init: true)

  class << self
    # Every migration in `dir`, oldest first. `dir` defaults to the primary
    # migrations path, which is the only one this repo has — the cable
    # database's `db/cable_migrate` is configured but not a directory here.
    #
    # A file the glob or FILENAME rejects is not one this guard has anything to
    # say about. That is narrower than "not a migration": Rails also raises
    # IllegalMigrationNameError on a file the glob matches and the regexp does
    # not (`20260101000000_AddFoo.rb`), which this deliberately does not cover —
    # it is a different error with a different fix, and one file is enough to
    # trigger it, so there is no pair to report.
    def migrations(dir = MIGRATION_DIR)
      parse(Dir[File.join(dir, GLOB)].sort.map { |path| path.delete_prefix("#{dir}/") })
    end

    # The same reduction over a list of paths relative to db/migrate, for a
    # tree that is not on disk — another branch, read out of git.
    def parse(relative_paths)
      relative_paths.sort.filter_map do |relative_path|
        match = FILENAME.match(File.basename(relative_path))
        next unless match

        Migration.new(
          relative_path: relative_path,
          version: match[1].to_i,
          class_name: camelize(match[2])
        )
      end
    end

    # Both collisions Rails raises on. Names first, which is the order Rails
    # itself validates in, so the first message here is the error it would have
    # reported.
    def collisions(dir = MIGRATION_DIR)
      duplicates_in(migrations(dir))
    end

    # The collisions a pull request would put on `main` if it merged now.
    #
    # The check above reads one tree, and on a pull request that tree is the
    # merge with `main` as of the PR's last push. Nothing re-reads it when
    # `main` moves afterwards, so two PRs that each passed can still collide
    # once both merge — #1483 and #1484 each claimed 20261111120000, a day
    # apart, two days after either last ran CI (zimmer#1500).
    #
    # So this rebuilds the merged tree from `main` as it is now plus what the
    # PR changes: `main`'s migrations, less the ones the PR deletes or renames
    # away, plus the ones it adds. All three are paths relative to db/migrate.
    #
    # Only collisions that include a file the PR adds are reported. One that is
    # already on `main` is `main`'s to fix — its own `lint` run is red — and
    # failing every open PR over it would bury the PR that fixes it.
    def merge_collisions(main:, added:, removed:)
      merged = (main - removed) | added

      duplicates_in(parse(merged)).select { |collision| collision.paths.intersect?(added) }
    end

    # What a contributor reads when the guard fails. Empty string when clean, so
    # it doubles as the standalone command's output.
    def report(collisions = self.collisions)
      collisions.map { |collision| collision_message(collision) }.join("\n")
    end

    private

    # `String#camelize` over the `[_a-z0-9]*` domain FILENAME allows, without
    # Active Support — which the guard cannot load. Verified equal on that
    # domain, including the pairs that matter: `add_widget_2` and `add_widget2`
    # both become `AddWidget2`.
    def camelize(name)
      name.split("_").map(&:capitalize).join
    end

    def duplicates_in(found)
      duplicates(found, :class_name) + duplicates(found, :version)
    end

    def duplicates(found, attribute)
      found.group_by(&attribute)
        .select { |_value, group| group.size > 1 }
        .map do |value, group|
          Collision.new(kind: attribute, value: value, paths: group.map(&:relative_path))
        end
    end

    ERROR_CLASSES = {
      version: "DuplicateMigrationVersionError",
      class_name: "DuplicateMigrationNameError"
    }.freeze

    FIXES = {
      version: <<~FIX,
        Renumber the newer migration to a timestamp nothing else has claimed, and
        re-dump db/schema.rb so its `version:` matches the newest migration:

          RAILS_ENV=test bin/rails db:drop db:create db:migrate

        Generating migrations with `bin/rails generate migration` instead of
        hand-writing the timestamp avoids this within a branch. It does not avoid
        it across branches: two branches that each pick a timestamp collide only
        once both have merged.
      FIX
      class_name: <<~FIX
        Rename the newer migration — its file and its class — to something the
        other one does not already call itself. Rails compares the camelized
        name only: the version is not part of it, so two different timestamps
        do not make a repeated name unique, and neither does an underscore
        (`add_widget_2` and `add_widget2` are both AddWidget2).
      FIX
    }.freeze

    KINDS = { version: "version", class_name: "class name" }.freeze

    def collision_message(collision)
      <<~MESSAGE
        #{collision.paths.size} migrations share the #{KINDS.fetch(collision.kind)} #{collision.value}:
        #{collision.paths.map { |path| "  db/migrate/#{path}" }.join("\n")}

        Rails builds its migration list at boot and raises
        ActiveRecord::#{ERROR_CLASSES.fetch(collision.kind)} rather than picking
        one. `maintain_test_schema!` walks that list, so this does not fail a
        test — it kills the whole suite before any test runs (zimmer#1005 /
        #1008).

        #{FIXES.fetch(collision.kind).strip}
      MESSAGE
    end
  end
end
