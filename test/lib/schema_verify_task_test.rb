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

  # The catalog is the half of the check that sees what the Ruby dump cannot
  # (https://github.com/tadasant/zimmer/issues/780). It fails in the same
  # direction as the replay set: a query that sees nothing makes both passes agree
  # and reports OK. So every kind it claims to cover is built here, inside this
  # test's transaction, and has to show up.
  def catalog
    SchemaVerifyTask.catalog(ActiveRecord::Base.connection)
  end

  test "the catalog sees the gate_decisions trigger and function db/schema.rb built" do
    assert catalog.any? { |line| line.start_with?("CREATE TRIGGER gate_decisions_append_only ") }
    assert catalog.any? { |line| line.start_with?("CREATE OR REPLACE FUNCTION public.gate_decisions_append_only()") }
  end

  test "the catalog sees every kind of object it claims to cover" do
    before = catalog
    connection = ActiveRecord::Base.connection
    [
      "CREATE VIEW zz_probe_view AS SELECT 1 AS one",
      "CREATE MATERIALIZED VIEW zz_probe_matview AS SELECT 1 AS one",
      "CREATE TABLE zz_probe_rules (id int)",
      "CREATE RULE zz_probe_rule AS ON DELETE TO zz_probe_rules DO INSTEAD NOTHING",
      "ALTER TABLE zz_probe_rules ENABLE ROW LEVEL SECURITY",
      "CREATE POLICY zz_probe_policy ON zz_probe_rules USING (id > 0)",
      "CREATE TYPE zz_probe_enum AS ENUM ('a', 'b')",
      "CREATE DOMAIN zz_probe_domain AS text CHECK (VALUE <> '')",
      "CREATE TYPE zz_probe_composite AS (a int, b text)",
      "CREATE TYPE zz_probe_range AS RANGE (SUBTYPE = int4)",
      "CREATE SEQUENCE zz_probe_sequence",
      "CREATE AGGREGATE zz_probe_aggregate (int) (SFUNC = int4pl, STYPE = int)",
      "CREATE UNLOGGED TABLE zz_probe_unlogged (id int)",
      "CREATE TABLE zz_probe_partitioned (id int) PARTITION BY RANGE (id)",
      "CREATE TABLE zz_probe_exclusion (r int4range, EXCLUDE USING gist (r WITH &&))",
      "CREATE TABLE zz_probe_child () INHERITS (zz_probe_rules)",
      "CREATE TABLE zz_probe_partition PARTITION OF zz_probe_partitioned FOR VALUES FROM (0) TO (10)",
      "CREATE TABLE zz_probe_fill (id int) WITH (fillfactor = 70)",
      "CREATE FUNCTION zz_probe_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$",
      "CREATE TRIGGER zz_probe_trigger BEFORE INSERT ON zz_probe_rules FOR EACH ROW EXECUTE FUNCTION zz_probe_fn()",
      "ALTER TABLE zz_probe_rules DISABLE TRIGGER zz_probe_trigger"
    ].each { |sql| connection.execute(sql) }

    added = catalog - before

    {
      "VIEW zz_probe_view AS" => "view",
      "MATERIALIZED VIEW zz_probe_matview AS" => "materialized view",
      "CREATE RULE zz_probe_rule AS" => "rule",
      "ROW LEVEL SECURITY ON zz_probe_rules" => "row-level security",
      "POLICY zz_probe_policy ON public.zz_probe_rules" => "policy",
      "TYPE zz_probe_enum AS ENUM ('a', 'b')" => "enum",
      "TYPE zz_probe_domain AS DOMAIN text CHECK" => "domain",
      "TYPE zz_probe_composite AS (a integer, b text)" => "composite type",
      "TYPE zz_probe_range AS RANGE (SUBTYPE = integer)" => "range type",
      "SEQUENCE zz_probe_sequence" => "standalone sequence",
      "AGGREGATE zz_probe_aggregate(integer)" => "aggregate",
      "TABLE zz_probe_unlogged UNLOGGED" => "unlogged table",
      "TABLE zz_probe_partitioned PARTITION BY RANGE (id)" => "partitioned table",
      "EXCLUSION CONSTRAINT ON zz_probe_exclusion EXCLUDE USING gist" => "exclusion constraint",
      "TABLE zz_probe_child INHERITS (zz_probe_rules)" => "inheriting table",
      "TABLE zz_probe_partition PARTITION OF zz_probe_partitioned FOR VALUES FROM (0) TO (10)" => "partition",
      "TABLE zz_probe_fill WITH (fillfactor=70)" => "table with storage parameters",
      "CREATE OR REPLACE FUNCTION public.zz_probe_fn()" => "function",
      "CREATE TRIGGER zz_probe_trigger BEFORE INSERT ON public.zz_probe_rules" => "trigger"
    }.each do |prefix, kind|
      assert added.any? { |line| line.start_with?(prefix) }, "the catalog does not see a #{kind}:\n#{added.join("\n")}"
    end

    trigger = added.find { |line| line.start_with?("CREATE TRIGGER zz_probe_trigger ") }
    assert trigger.end_with?(" -- disabled"), "a disabled trigger reads the same as an enabled one: #{trigger}"
  end

  test "the catalog leaves out what the dump already carries as a table" do
    before = catalog

    ActiveRecord::Base.connection.execute("CREATE TABLE zz_probe_plain (id bigserial PRIMARY KEY, name text)")

    assert_equal before, catalog, "a plain table, its row type or its id sequence is being listed"
  end
end
