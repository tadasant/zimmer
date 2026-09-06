# frozen_string_literal: true

require "test_helper"

# `db:schema:verify` is a merge-gate job now, so the way it can fail is no longer
# "it goes red" — it is "it goes green while comparing nothing". Everything below
# is about the replay set: which schema dumps a from-zero `db:migrate` is expected
# to reproduce. Get that wrong in the empty direction and every comparison in
# `run` is trivially true.
class SchemaVerifyTaskTest < ActiveSupport::TestCase
  def replayable
    SchemaVerifyTask.send(:replayable_paths).map { |path| path.relative_path_from(Rails.root).to_s }
  end

  def all_paths
    SchemaVerifyTask.send(:schema_paths).map { |path| path.relative_path_from(Rails.root).to_s }
  end

  test "the replay set holds the primary database, whose migrations are in db/migrate" do
    assert_includes replayable, "db/schema.rb"
  end

  test "the replay set excludes the cable database, which is installed from a schema file" do
    assert_includes all_paths, "db/cable_schema.rb",
      "db/cable_schema.rb is no longer a dump path for this environment — if solid_cable's " \
      "wiring changed, the exclusion below is describing something that no longer exists."

    assert_not_includes replayable, "db/cable_schema.rb",
      "db/cable_schema.rb is in the replay set, but db/cable_migrate holds no migrations — a " \
      "from-zero db:migrate dumps that database empty, so the check would fail forever."
  end

  test "the replay set is never empty, which is how this check passes while verifying nothing" do
    assert_not_empty replayable
  end

  # The near-miss glob this replaced was `*.rb`, non-recursive and version-blind.
  # A db/migrate reorganized into subdirectories would have emptied the replay
  # set silently.
  test "a database counts as replayable on the same glob db:migrate itself uses" do
    config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "primary")

    assert SchemaVerifyTask.send(:migrations?, config)
  end

  test "a database whose migrations_paths does not exist is not replayable" do
    config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "cable")

    assert_not SchemaVerifyTask.send(:migrations?, config)
  end
end
