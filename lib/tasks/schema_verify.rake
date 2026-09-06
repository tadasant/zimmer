# frozen_string_literal: true

# `SchemaVerifyTask` itself lives in lib/schema_verify_task.rb (autoloaded), not
# here: lib/tasks is excluded from `config.autoload_lib`, and a module defined
# inside a .rake file cannot be required from a test.

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
