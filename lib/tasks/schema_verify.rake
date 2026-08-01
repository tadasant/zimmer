# frozen_string_literal: true

# CI never runs the migrations: `bin/rails db:test:prepare` *loads* `db/schema.rb`
# and no job migrates from zero. So a schema.rb that has drifted from what the
# migrations actually produce — a hand-edited entry, a migration whose reformat
# was thrown away, a column the schema declares that no migration creates —
# passes every check the merge gate has, and only bites whoever next runs
# `db:migrate` against an empty database.
#
# `db:schema:verify` is that missing check, on demand and outside CI: migrate a
# scratch database from zero and dump it, load the committed schema into a
# scratch database and dump that, then compare the two dumps.
#
# Destructive — it drops and recreates the environment's databases — so it
# refuses to run outside the test environment.
module SchemaVerifyTask
  class << self
    def run
      committed = read_schemas
      # Set only when a dump that disagrees with the committed files is worth
      # leaving in the tree for the author to review and commit.
      keep = nil

      begin
        puts "==> migrating a scratch database from zero"
        from_migrations = migrate_pass

        puts "==> loading the committed schema into a scratch database"
        from_schema_load = schema_load_pass(committed)

        if from_migrations != from_schema_load
          abort "DRIFT: migrating from zero and loading the committed schema produce different dumps — " \
                "a migration and the committed schema disagree. Diff them to see which objects differ."
        elsif from_migrations == committed
          puts "OK: #{describe(committed.keys)} match both a from-zero migration and a schema load."
        else
          keep = from_migrations
          abort "DRIFT: the migrations and the committed schema agree with each other but not with the " \
                "files in the tree. They have been rewritten in place — review and commit them."
        end
      ensure
        # Runs on success, on abort (SystemExit), and on Ctrl-C (Interrupt), so a
        # scratch dump is never left behind in the working tree.
        write_schemas(keep || committed)
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
    # because solid_cable declares a second database, `db/cable_schema.rb`. The
    # passes rewrite all of them, so all of them are snapshotted and compared.
    def schema_paths
      ActiveRecord::Base.configurations
        .configs_for(env_name: Rails.env)
        .filter_map { |db_config| ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config) }
        .uniq
        .map { |path| Pathname.new(path) }
    end

    def read_schemas
      schema_paths.index_with { |path| path.exist? ? path.read : nil }
    end

    def write_schemas(contents)
      contents.each { |path, body| path.write(body) if body && (!path.exist? || path.read != body) }
    end

    def describe(paths)
      paths.map { |path| path.relative_path_from(Rails.root) }.join(" and ")
    end
  end
end

namespace :db do
  namespace :schema do
    desc "Verify the schema dumps round-trip: migrating from zero and loading the schema produce the same dump"
    task verify: :environment do
      unless Rails.env.test?
        abort "db:schema:verify drops and recreates databases; run it with RAILS_ENV=test (got #{Rails.env})"
      end

      SchemaVerifyTask.run
    end
  end
end
