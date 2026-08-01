# frozen_string_literal: true

# CI never runs the migrations: `bin/rails db:test:prepare` *loads* `db/schema.rb`
# and no job migrates from zero. So a schema.rb that has drifted from what the
# migrations actually produce — a hand-edited entry, a migration whose reformat
# was thrown away, a dump taken under an older Active Record version — passes
# every check the merge gate has, and only bites whoever next runs `db:migrate`.
#
# `db:schema:verify` is that missing check, on demand and outside CI: migrate a
# scratch database from zero and dump it, load the committed schema into a
# scratch database and dump that, then compare the two dumps against each other
# and against the committed file.
#
# Destructive — it drops and recreates the environment's databases — so it
# refuses to run outside the test environment.
module SchemaVerifyTask
  SCHEMA_PATH = Rails.root.join("db/schema.rb")

  class << self
    def run
      committed = SCHEMA_PATH.read

      from_migrations = dump_after { Rake::Task["db:migrate"].invoke }
      write(committed)
      from_schema_load = dump_after { Rake::Task["db:schema:load"].invoke }

      if from_migrations != from_schema_load
        write(committed)
        abort "DRIFT: migrating from zero and loading db/schema.rb produce different dumps — " \
              "a migration and the committed schema disagree."
      end

      write(from_migrations)
      if from_migrations == committed
        puts "OK: db/schema.rb matches both a from-zero migration and a schema load."
      else
        abort "DRIFT: the migrations and db/schema.rb agree with each other but not with the " \
              "committed file. db/schema.rb has been rewritten in place — review and commit it."
      end
    rescue StandardError
      write(committed) if committed
      raise
    end

    private

    # Rebuild every configured database for this environment from nothing, run
    # the given step, and return the schema it dumps.
    def dump_after
      invoke("db:drop")
      invoke("db:create")
      yield
      invoke("db:schema:dump")
      SCHEMA_PATH.read
    end

    # Rake tasks only run once per process unless re-enabled, and this task
    # invokes several of them twice.
    def invoke(name)
      Rake::Task[name].reenable
      Rake::Task[name].invoke
    end

    def write(contents)
      SCHEMA_PATH.write(contents) unless SCHEMA_PATH.read == contents
    end
  end
end

namespace :db do
  namespace :schema do
    desc "Verify db/schema.rb round-trips: migrating from zero and loading the schema produce the same dump"
    task verify: :environment do
      unless Rails.env.test?
        abort "db:schema:verify drops and recreates databases; run it with RAILS_ENV=test (got #{Rails.env})"
      end

      SchemaVerifyTask.run
    end
  end
end
