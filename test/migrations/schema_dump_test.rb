# frozen_string_literal: true

require "test_helper"

# `db/schema.rb` sat at `ActiveRecord::Schema[8.0]` while the app ran Active
# Record 8.1 (https://github.com/tadasant/zimmer/issues/182). Nothing noticed,
# because CI only ever *loads* the schema — `bin/rails db:test:prepare` — and
# never migrates. The cost landed on the next person to run `db:migrate`: the
# 8.1 dumper reformats all ~450 lines (header bump, alphabetized tables and
# columns), so every migration PR carried an unreviewable whole-file diff, and
# the usual escape was to throw the reformat away and hand-write the entry —
# which is how a schema.rb drifts from what the migrations actually produce.
#
# These assertions are the cheap half of the guard: they run in CI on every PR
# and catch a stale dump the moment the Rails version moves, or a schema version
# that no longer matches the migrations on disk. The expensive half — proving
# that migrating from zero and loading the schema produce the same database — is
# `bin/rails db:schema:verify` (lib/tasks/schema_verify.rake), which needs to
# drop and recreate databases and so stays out of the merge gate.
class SchemaDumpTest < ActiveSupport::TestCase
  SCHEMA_FILES = [ Rails.root.join("db/schema.rb"), Rails.root.join("db/cable_schema.rb") ].freeze

  SCHEMA_HEADER = /ActiveRecord::Schema\[(\d+\.\d+)\]\.define\(version: ([0-9_]+)\)/

  test "every schema dump is in the running Active Record version's format" do
    # ActiveRecord::Migration.current_version is a Float (8.1), and the header
    # renders it the same way.
    expected = ActiveRecord::Migration.current_version.to_s

    SCHEMA_FILES.each do |path|
      header = path.read[SCHEMA_HEADER, 1]
      assert header, "#{path.basename} has no ActiveRecord::Schema[...] header"
      assert_equal expected, header,
        "#{path.basename} is a #{header}-format dump but Active Record is #{expected}. " \
        "Re-dump it (RAILS_ENV=test bin/rails db:drop db:create db:migrate) in its own commit — " \
        "otherwise the next db:migrate reformats the whole file inside an unrelated PR."
    end
  end

  # Scoped to db/schema.rb alone: db/cable_schema.rb belongs to the solid_cable
  # database, whose migrations_paths (db/cable_migrate) is not a directory in this
  # repo, so it has no "newest migration" to be at.
  test "db/schema.rb is dumped at the newest migration on disk" do
    newest = Dir.children(Rails.root.join("db/migrate"))
      .filter_map { |name| name[/\A(\d{14})_/, 1] }
      .max

    assert newest, "no migrations found in db/migrate"

    dumped = Rails.root.join("db/schema.rb").read[SCHEMA_HEADER, 2].delete("_")

    assert_equal newest, dumped,
      "db/schema.rb is at version #{dumped} but the newest migration is #{newest}. " \
      "The schema was not re-dumped after the migration was added."
  end
end
