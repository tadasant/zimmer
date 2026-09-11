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
# Comparing dumps alone is blind to anything the dumper does not write down, and
# the Ruby dumper does not write down most of what a migration can install with
# `execute`: a view, a rule, a policy, a domain. Both dumps leave it out, so they
# agree, and the object exists in production and nowhere else
# (https://github.com/tadasant/zimmer/issues/780). So each pass also reads a
# CATALOG of those objects straight from Postgres, and the two catalogs must
# agree too.
#
# Destructive — it drops and recreates the environment's databases — so it
# refuses to run outside the test environment.
module SchemaVerifyTask
  # Where the `db:schema:verify:catalog` step of each pass writes what it read.
  CATALOG_ENV = "SCHEMA_VERIFY_CATALOG_PATH"

  # Schemas Postgres owns. Everything else is the app's.
  USER_SCHEMA = "n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'"

  # An object an extension owns comes back with `enable_extension`, which the dump
  # already carries.
  def self.extension_member(catalog, oid)
    "EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = '#{catalog}'::regclass " \
      "AND d.objid = #{oid} AND d.deptype = 'e')"
  end

  # Every kind of object a migration can build that is not a column or an index,
  # one query per kind, each returning one self-describing line per object. Kinds
  # the dump does carry (enums, exclusion constraints, functions and triggers) are
  # listed too: they cost nothing when the two passes agree, and they catch the
  # dumper getting one wrong.
  CATALOG = {
    "functions" => <<~SQL,
      SELECT CASE WHEN p.prokind = 'a' THEN 'AGGREGATE ' || p.oid::regprocedure::text
                  ELSE pg_get_functiondef(p.oid) END
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE #{USER_SCHEMA} AND NOT #{extension_member("pg_proc", "p.oid")}
    SQL
    "triggers" => <<~SQL,
      SELECT pg_get_triggerdef(t.oid) || CASE t.tgenabled WHEN 'O' THEN '' WHEN 'D' THEN ' -- disabled'
                                              WHEN 'R' THEN ' -- enabled replica' ELSE ' -- enabled always' END
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE #{USER_SCHEMA} AND NOT t.tgisinternal
    SQL
    "event triggers" => <<~SQL,
      SELECT 'EVENT TRIGGER ' || quote_ident(e.evtname) || ' ON ' || e.evtevent || ' EXECUTE FUNCTION ' ||
             e.evtfoid::regproc::text || CASE e.evtenabled WHEN 'D' THEN ' -- disabled' ELSE '' END
      FROM pg_event_trigger e
      WHERE NOT #{extension_member("pg_event_trigger", "e.oid")}
    SQL
    "views" => <<~SQL,
      SELECT CASE c.relkind WHEN 'v' THEN 'VIEW ' ELSE 'MATERIALIZED VIEW ' END || c.oid::regclass::text ||
             ' AS ' || pg_get_viewdef(c.oid)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE #{USER_SCHEMA} AND c.relkind IN ('v', 'm') AND NOT #{extension_member("pg_class", "c.oid")}
    SQL
    # pg_rules already leaves out the rule every view is built on.
    "rules" => <<~SQL,
      SELECT r.definition FROM pg_rules r
      WHERE r.schemaname <> 'information_schema' AND r.schemaname !~ '^pg_'
    SQL
    "row-level security" => <<~SQL,
      SELECT format('POLICY %I ON %I.%I AS %s FOR %s TO %s USING (%s) WITH CHECK (%s)', p.policyname,
                    p.schemaname, p.tablename, p.permissive, p.cmd, array_to_string(p.roles, ', '),
                    p.qual, p.with_check)
      FROM pg_policies p
      WHERE p.schemaname <> 'information_schema' AND p.schemaname !~ '^pg_'
      UNION ALL
      SELECT 'ROW LEVEL SECURITY ON ' || c.oid::regclass::text ||
             CASE WHEN c.relforcerowsecurity THEN ' (FORCE)' ELSE '' END
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE #{USER_SCHEMA} AND (c.relrowsecurity OR c.relforcerowsecurity)
    SQL
    # Standalone composite types only: every table has a row type, and the table is
    # already in the dump.
    "types" => <<~SQL,
      SELECT 'TYPE ' || t.oid::regtype::text || ' AS ' || CASE t.typtype
        WHEN 'e' THEN 'ENUM (' || coalesce((SELECT string_agg(quote_literal(e.enumlabel), ', ' ORDER BY e.enumsortorder)
                                              FROM pg_enum e WHERE e.enumtypid = t.oid), '') || ')'
        WHEN 'd' THEN 'DOMAIN ' || format_type(t.typbasetype, t.typtypmod) ||
                      CASE WHEN t.typnotnull THEN ' NOT NULL' ELSE '' END ||
                      coalesce(' DEFAULT ' || t.typdefault, '') ||
                      coalesce((SELECT ' ' || string_agg(pg_get_constraintdef(k.oid), ' ' ORDER BY k.conname)
                                FROM pg_constraint k WHERE k.contypid = t.oid), '')
        WHEN 'r' THEN 'RANGE (SUBTYPE = ' || coalesce((SELECT format_type(r.rngsubtype, NULL)
                                                         FROM pg_range r WHERE r.rngtypid = t.oid), '') || ')'
        ELSE '(' || coalesce((SELECT string_agg(quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod),
                                                ', ' ORDER BY a.attnum)
                                FROM pg_attribute a
                                WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped), '') || ')'
      END
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE #{USER_SCHEMA} AND NOT #{extension_member("pg_type", "t.oid")}
        AND (t.typtype IN ('e', 'd', 'r')
             OR (t.typtype = 'c' AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c')))
    SQL
    # Sequences a column owns — every `id` — come back with their table.
    "sequences" => <<~SQL,
      SELECT 'SEQUENCE ' || c.oid::regclass::text
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE #{USER_SCHEMA} AND c.relkind = 'S' AND NOT #{extension_member("pg_class", "c.oid")}
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                          AND d.refobjsubid > 0 AND d.deptype IN ('a', 'i'))
    SQL
    "exclusion constraints" => <<~SQL,
      SELECT 'CONSTRAINT ' || quote_ident(k.conname) || ' ON ' || k.conrelid::regclass::text || ' ' ||
             pg_get_constraintdef(k.oid)
      FROM pg_constraint k JOIN pg_namespace n ON n.oid = k.connamespace
      WHERE #{USER_SCHEMA} AND k.contype = 'x'
    SQL
    # How a table is stored, as opposed to what it holds: partitioning,
    # inheritance, UNLOGGED, storage parameters. Only tables with one are listed.
    "table storage" => <<~SQL
      SELECT 'TABLE ' || c.oid::regclass::text || concat_ws('',
        CASE WHEN c.relkind = 'p' THEN ' PARTITION BY ' || pg_get_partkeydef(c.oid) END,
        CASE WHEN c.relispartition THEN ' PARTITION OF ' ||
          (SELECT i.inhparent::regclass::text FROM pg_inherits i WHERE i.inhrelid = c.oid) || ' ' ||
          pg_get_expr(c.relpartbound, c.oid) END,
        CASE WHEN NOT c.relispartition THEN
          (SELECT ' INHERITS (' || string_agg(i.inhparent::regclass::text, ', ' ORDER BY i.inhseqno) || ')'
           FROM pg_inherits i WHERE i.inhrelid = c.oid) END,
        CASE WHEN c.relpersistence = 'u' THEN ' UNLOGGED' END,
        CASE WHEN c.reloptions IS NOT NULL THEN ' WITH (' || array_to_string(c.reloptions, ', ') || ')' END)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE #{USER_SCHEMA} AND c.relkind IN ('r', 'p') AND NOT #{extension_member("pg_class", "c.oid")}
        AND (c.relkind = 'p' OR c.relispartition OR c.relpersistence = 'u' OR c.reloptions IS NOT NULL
             OR EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid))
    SQL
  }.freeze

  class << self
    # What CATALOG finds in the database behind `connection`, one line per object,
    # sorted so two databases built in a different order still compare equal.
    def catalog(connection)
      CATALOG.values.flat_map { |sql| connection.select_values(sql, "SCHEMA") }.compact.sort
    end

    # The last step of each pass, run inside that pass's `bin/rails` process: read
    # the catalog of every replayable database and leave it at `path` as JSON for
    # the parent to compare. Keyed by dump path, like everything else here.
    def write_catalog(path)
      catalogs = configs.select { |db_config| migrations?(db_config) }.to_h do |db_config|
        ActiveRecord::Base.establish_connection(db_config)
        dump = Pathname.new(ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config))
        [ dump.relative_path_from(Rails.root).to_s, ActiveRecord::Base.connection_pool.with_connection { |c| catalog(c) } ]
      end
      File.write(path, JSON.generate(catalogs))
    end

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
        from_migrations, migrated_catalog = migrate_pass

        puts "==> loading the committed schema into a scratch database"
        from_schema_load, loaded_catalog = schema_load_pass(committed)

        replayed = from_migrations.slice(*replayable)
        loaded = from_schema_load.slice(*replayable)

        if replayed != loaded
          abort "DRIFT: migrating from zero and loading the committed schema produce different dumps — " \
                "a migration and the committed schema disagree.\n\n" \
                "#{diff(loaded, replayed, from: "schema-load", to: "migrated-from-zero")}"
        elsif migrated_catalog != loaded_catalog
          abort "DRIFT: the migrations build database objects that loading the committed schema does not. " \
                "db/schema.rb is a Ruby dump: it carries tables, indexes, constraints, enums, functions and " \
                "triggers, and nothing else a migration installs with `execute`. What is listed below exists " \
                "after `db:migrate` — in production — and is missing from CI, from test, and from every " \
                "database built with `db:schema:load`. Build it with something the dump carries, or teach " \
                "config/initializers/schema_dump_functions_and_triggers.rb to dump it.\n\n" \
                "#{catalog_diff(loaded_catalog, migrated_catalog)}"
        elsif from_schema_load == committed
          objects = migrated_catalog.values.sum(&:size)
          puts "OK: #{describe(loaded.keys)} — a from-zero migration and a schema load produce the same dump, " \
               "and the same #{objects} #{"object".pluralize(objects)} outside tables and indexes."
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
      catalog = without_schema_files do
        run!("db:drop", "db:create", "db:migrate", "db:schema:dump",
             failure: "the migrations are not replayable from zero — `db:migrate` failed against an " \
                      "empty database (see the error above). db/schema.rb declares objects that " \
                      "db/migrate/ cannot build.")
      end
      [ read_schemas, catalog ]
    end

    def schema_load_pass(committed)
      write_schemas(committed)
      catalog = run!("db:drop", "db:create", "db:schema:load", "db:schema:dump",
                     failure: "the committed schema could not be loaded into an empty database (see the error above).")
      [ read_schemas, catalog ]
    end

    # Each pass is a separate `bin/rails` process on purpose. Driving these tasks
    # in-process does not work: `db:drop` is a shell around `db:drop:_unsafe` and
    # Rake#reenable does not cascade into a task's inner invocations, so the second
    # pass would silently skip the drop and run against the first pass's database.
    #
    # The pass ends by reading its database's catalog in that same process, so the
    # read costs no extra boot and this process never holds a connection that
    # would stop the next pass's `db:drop`. Returns that catalog.
    def run!(*tasks, failure:)
      Tempfile.create([ "schema-verify-catalog", ".json" ]) do |file|
        ok = system({ "RAILS_ENV" => "test", CATALOG_ENV => file.path },
                    Rails.root.join("bin/rails").to_s, *tasks, "db:schema:verify:catalog")
        abort "FAILED: #{failure}" unless ok
        JSON.parse(File.read(file.path))
      end
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

    def catalog_diff(loaded, migrated)
      (loaded.keys | migrated.keys).filter_map do |key|
        before = loaded.fetch(key, [])
        after = migrated.fetch(key, [])
        next if before == after

        label = "#{key} database objects"
        unified_diff(before.map { |line| "#{line}\n" }.join, after.map { |line| "#{line}\n" }.join,
                     "#{label} (schema-load)", "#{label} (migrated-from-zero)").presence ||
          "#{label} only after migrating from zero:\n#{(after - before).join("\n")}\n\n" \
          "#{label} only after a schema load:\n#{(before - after).join("\n")}"
      end.join("\n")
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
