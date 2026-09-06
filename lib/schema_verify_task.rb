# frozen_string_literal: true

require "open3"
require "tempfile"

# The test suite never runs the migrations: `bin/rails db:test:prepare` *loads*
# `db/schema.rb`. So a schema.rb that has drifted from what the migrations
# actually produce — a hand-edited entry, a migration whose reformat was thrown
# away, a column the schema declares that no migration creates — passes every
# other check the merge gate has, and only bites whoever next runs `db:migrate`
# against an empty database.
#
# `db:schema:verify` is that missing check: migrate a scratch database from zero
# and dump it, load the committed schema into a scratch database and dump that,
# then compare the two dumps. The `schema_verify` job in .github/workflows/ci.yml
# runs it on every PR against a throwaway Postgres service container.
#
# Destructive — it drops and recreates the environment's databases — so it
# refuses to run outside the test environment.
module SchemaVerifyTask
  class << self
    def run
      committed = read_schemas
      replayable = replayable_paths
      # A replay set that has emptied out — a reorganized db/migrate, a renamed
      # dump path — would make every comparison below trivially true and report
      # OK forever. That is the defect this check exists to catch, one level
      # down, so refuse to run rather than pass.
      abort "FAILED: no database in this environment has migrations to replay, so this check would " \
            "compare nothing and pass. Look at db/migrate/ and config/database.yml." if replayable.empty?

      # Set only when a dump that disagrees with the committed files is worth
      # leaving in the tree for the author to review and commit.
      keep = nil

      begin
        puts "==> migrating a scratch database from zero"
        from_migrations = migrate_pass

        puts "==> loading the committed schema into a scratch database"
        from_schema_load = schema_load_pass(committed)

        replayed = from_migrations.slice(*replayable)
        loaded = from_schema_load.slice(*replayable)

        if replayed != loaded
          abort "DRIFT: migrating from zero and loading the committed schema produce different dumps — " \
                "a migration and the committed schema disagree.\n\n" \
                "#{diff(loaded, replayed, from: "schema-load", to: "migrated-from-zero")}"
        elsif from_schema_load == committed
          puts "OK: #{describe(loaded.keys)} — a from-zero migration and a schema load produce the same dump."
          skipped = committed.keys - loaded.keys
          if skipped.any?
            puts "    #{describe(skipped)} — no migrations to replay; checked by schema load and re-dump only."
          end
        else
          keep = from_schema_load
          abort "DRIFT: the migrations and the committed schema agree with each other but not with the " \
                "files in the tree. They have been rewritten in place — review and commit them.\n\n" \
                "#{diff(committed, from_schema_load, from: "committed", to: "re-dumped")}"
        end
      ensure
        # Runs on success, on abort (SystemExit), and on Ctrl-C (Interrupt), so a
        # scratch dump is never left behind in the working tree. `keep` is merged
        # over the committed bodies rather than replacing them, so a path whose
        # dump came back nil is restored instead of left deleted.
        write_schemas(committed.merge((keep || {}).compact))
      end
    end

    private

    # Run the migrations against an empty database and return what they dump.
    #
    # The schema files are moved out of the way first, and that is not incidental:
    # `db:migrate` against a database with no `schema_migrations` table does not
    # run the migrations at all — it loads `db/schema.rb` and stamps every version
    # as applied. With the files present, this pass would silently re-dump the
    # committed schema and the whole check would compare it against itself.
    def migrate_pass
      without_schema_files do
        run!("db:drop", "db:create", "db:migrate", "db:schema:dump",
             failure: "the migrations are not replayable from zero — `db:migrate` failed against an " \
                      "empty database (see the error above). db/schema.rb declares objects that " \
                      "db/migrate/ cannot build.")
      end
      read_schemas
    end

    def schema_load_pass(committed)
      write_schemas(committed)
      run!("db:drop", "db:create", "db:schema:load", "db:schema:dump",
           failure: "the committed schema could not be loaded into an empty database (see the error above).")
      read_schemas
    end

    # Each pass is a separate `bin/rails` process on purpose. Driving these tasks
    # in-process does not work: `db:drop` is a shell around `db:drop:_unsafe` and
    # Rake#reenable does not cascade into a task's inner invocations, so the second
    # pass would silently skip the drop and run against the first pass's database.
    def run!(*tasks, failure:)
      ok = system({ "RAILS_ENV" => "test" }, Rails.root.join("bin/rails").to_s, *tasks)
      abort "FAILED: #{failure}" unless ok
    end

    def without_schema_files
      stashed = read_schemas
      stashed.each_key { |path| path.delete if path.exist? }
      yield
    ensure
      # Only restore paths the passes did not regenerate; db:schema:dump recreates
      # them on success, and the caller's own ensure has the final say either way.
      stashed.each { |path, body| path.write(body) if body && !path.exist? }
    end

    # Every schema file Rails dumps for this environment — `db/schema.rb` and,
    # because solid_cable declares a second database, `db/cable_schema.rb`. Both
    # passes rewrite all of them, so all of them are snapshotted and restored.
    def schema_paths
      configs.filter_map { |db_config| ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config) }
        .uniq
        .map { |path| Pathname.new(path) }
    end

    # The subset a from-zero `db:migrate` can actually reproduce.
    #
    # solid_cable's `cable` database is installed by loading `db/cable_schema.rb`
    # — the gem ships that file and no migration, and the `migrations_paths` the
    # config names (`db/cable_migrate`) is not a directory in this repo. A
    # from-zero migrate therefore dumps that database empty, which is the design
    # and not drift; comparing it against the committed file would fail forever.
    # It is still covered by the load-and-dump comparison in `run`, which is the
    # only one that means anything for a schema-only database. The same reasoning
    # scopes test/migrations/schema_dump_test.rb's version assertion.
    def replayable_paths
      configs.select { |db_config| migrations?(db_config) }
        .filter_map { |db_config| ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config) }
        .uniq
        .map { |path| Pathname.new(path) }
    end

    # The same glob `ActiveRecord::MigrationContext#migration_files` uses, so this
    # answers "would db:migrate find anything here" rather than a near-miss of it.
    def migrations?(db_config)
      Array(db_config.migrations_paths || ActiveRecord::Migrator.migrations_paths)
        .any? { |dir| Dir.glob(Rails.root.join(dir, "**", "[0-9]*_*.rb")).any? }
    end

    def configs
      ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
    end

    def read_schemas
      schema_paths.index_with { |path| path.exist? ? path.read : nil }
    end

    def write_schemas(contents)
      contents.each { |path, body| path.write(body) if body && (!path.exist? || path.read != body) }
    end

    # A CI log is the only place most readers will ever see this failure, and
    # "diff them yourself" is not something you can act on from one. Print the
    # difference, per file, in the message that fails the job.
    def diff(before, after, from:, to:)
      before.filter_map { |path, body| file_diff(path, body, after[path], from:, to:) }.join("\n")
    end

    def file_diff(path, before, after, from:, to:)
      return nil if before == after

      name = path.relative_path_from(Rails.root)
      body = unified_diff(before.to_s, after.to_s, "#{name} (#{from})", "#{name} (#{to})")
      body.presence || "#{name} differs between the #{from} and #{to} dumps."
    end

    def unified_diff(before, after, before_label, after_label)
      Tempfile.create("schema-verify-before") do |a|
        Tempfile.create("schema-verify-after") do |b|
          a.write(before)
          a.flush
          b.write(after)
          b.flush
          # 0 is identical and 1 is "they differ", which is the expected case
          # here. 2 is `diff` itself failing — a variant that rejects `--label`,
          # say — and capture2e merges its stderr into `out`, so returning that
          # would render a usage message as if it were the diff.
          out, status = Open3.capture2e(
            "diff", "-u", "--label", before_label, "--label", after_label, a.path, b.path
          )
          out if status.exitstatus.to_i <= 1
        end
      end
    rescue Errno::ENOENT
      # No `diff` on this box. The abort message above still names the files.
      nil
    end

    def describe(paths)
      paths.map { |path| path.relative_path_from(Rails.root) }.join(" and ")
    end
  end
end
