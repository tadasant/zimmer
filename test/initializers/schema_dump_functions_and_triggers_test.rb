# frozen_string_literal: true

require "test_helper"

# db/schema.rb carries functions and triggers because
# config/initializers/schema_dump_functions_and_triggers.rb writes them into it.
# Get that wrong and the dump still loads, still re-dumps, and quietly builds a
# test database without the guarantee production has — the defect in
# https://github.com/tadasant/zimmer/issues/780. `db:schema:verify` catches that
# end to end in its own CI job; these catch it inside `test-unit`.
class SchemaDumpFunctionsAndTriggersTest < ActiveSupport::TestCase
  def dump
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
  end

  # What a dumped `execute` block hands to Postgres when the schema is loaded.
  def loaded_sql(statement)
    captured = nil
    loader = Object.new
    loader.define_singleton_method(:execute) { |sql| captured = sql }
    loader.instance_eval(statement)
    captured
  end

  test "the test database, built from db/schema.rb, has the gate_decisions trigger and its function" do
    connection = ActiveRecord::Base.connection

    assert connection.select_value(<<~SQL), "db/schema.rb did not build the gate_decisions_append_only trigger"
      SELECT 1 FROM pg_trigger WHERE tgrelid = 'gate_decisions'::regclass AND tgname = 'gate_decisions_append_only'
    SQL
    assert connection.select_value("SELECT 1 FROM pg_proc WHERE proname = 'gate_decisions_append_only'"),
      "db/schema.rb did not build the gate_decisions_append_only function"
  end

  test "a function and a trigger are dumped after every table, the function first" do
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      CREATE FUNCTION zz_schema_dump_probe() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RETURN NEW;
      END;
      $$
    SQL
    connection.execute(<<~SQL)
      CREATE TRIGGER zz_schema_dump_probe BEFORE INSERT ON categories
      FOR EACH ROW EXECUTE FUNCTION zz_schema_dump_probe()
    SQL

    schema = dump
    function_at = schema.index("CREATE OR REPLACE FUNCTION public.zz_schema_dump_probe()")
    trigger_at = schema.index("CREATE TRIGGER zz_schema_dump_probe BEFORE INSERT ON public.categories")

    assert function_at, "the function is not in the dump"
    assert trigger_at, "the trigger is not in the dump"
    assert_operator function_at, :<, trigger_at, "the trigger is dumped before the function it calls"
    assert_operator schema.rindex("add_foreign_key"), :<, function_at, "functions are dumped before the tables"
    assert schema.rstrip.end_with?("end"), "the schema block is not closed after the functions and triggers"
  end

  test "a function body comes back from the dump byte for byte" do
    # An array rather than a heredoc, so the fixture is not itself dedented.
    body = [
      "CREATE OR REPLACE FUNCTION public.f()",
      " RETURNS text",
      " LANGUAGE plpgsql",
      "AS $function$",
      "BEGIN",
      "\t-- a tab-indented line, then a blank one, then one of only spaces",
      "",
      "   ",
      "  RETURN '\#{not ruby} \\n stays two characters';",
      "END;",
      "$function$"
    ].join("\n")

    statement = SchemaDumpFunctionsAndTriggers.execute_statement(body)

    assert_match(/\A  execute <<~'SQL'\n/, statement)
    assert_equal "#{body}\n", loaded_sql(statement)
  end

  test "a body with a line that would end the heredoc is dumped as a string instead" do
    body = "CREATE OR REPLACE FUNCTION public.f()\nAS $function$\nSQL\n$function$"

    statement = SchemaDumpFunctionsAndTriggers.execute_statement(body)

    assert_no_match(/<<~/, statement)
    assert_equal body, loaded_sql(statement)
  end

  # Ruby's parser drops a carriage return from the end of a heredoc line, so a
  # CRLF body could not come back byte for byte from one.
  test "a body with carriage returns is dumped as a string instead" do
    body = "CREATE OR REPLACE FUNCTION public.f()\r\nAS $function$\r\n  SELECT 1\r\n$function$"

    statement = SchemaDumpFunctionsAndTriggers.execute_statement(body)

    assert_no_match(/<<~/, statement)
    assert_equal body, loaded_sql(statement)
  end
end
