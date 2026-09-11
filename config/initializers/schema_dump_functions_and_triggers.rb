# frozen_string_literal: true

# db/schema.rb is a Ruby dump, and Rails' Ruby dumper writes down tables, indexes,
# constraints, enums and extensions and nothing else. A function or a trigger that
# a migration installs with `execute` exists in every database `db:migrate` builds
# — production — and silently does not exist in any database built by loading the
# dump: CI, test, and anything restored with `db:schema:load`
# (https://github.com/tadasant/zimmer/issues/780).
#
# This teaches the Postgres dumper to write those two down, as the SQL Postgres
# reports for them (`pg_get_functiondef`, `pg_get_triggerdef`), in `execute` blocks
# at the end of the schema. Loading the dump needs nothing but Postgres, and
# producing it needs no `pg_dump` — which the agent worker image, where most
# migrations here are written, does not have.
#
# Only functions and triggers. Views, rules, policies, domains and the rest are
# still not dumped, and `db:schema:verify` (lib/schema_verify_task.rb) fails any
# migration that builds one, because a schema load would not reproduce it. The
# same check catches a function or trigger this dumper gets wrong: it compares
# what Postgres reports after a from-zero migrate against what it reports after
# loading this dump.
module SchemaDumpFunctionsAndTriggers
  HEREDOC = "SQL"

  # Functions and procedures in the dumped schemas. Aggregates are left out
  # (`pg_get_functiondef` cannot render one), and so is anything an extension
  # owns, which `enable_extension` already recreates. Ordered by signature so the
  # dump is the same whichever order the migrations created them in. A plpgsql
  # body is not checked until it runs, so the order only matters for a SQL-language
  # function calling another — which a schema load would fail on, loudly.
  FUNCTIONS = <<~SQL
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = ANY (string_to_array(%{schemas}, ','))
      AND p.prokind IN ('f', 'p')
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
      )
    ORDER BY p.oid::regprocedure::text
  SQL

  # User triggers only: `tgisinternal` marks the ones Postgres creates to enforce
  # foreign keys, which `add_foreign_key` already recreates.
  TRIGGERS = <<~SQL
    SELECT c.relname, pg_get_triggerdef(t.oid)
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = ANY (string_to_array(%{schemas}, ','))
      AND NOT t.tgisinternal
    ORDER BY n.nspname, c.relname, t.tgname
  SQL

  # One `execute` per statement, as a squiggly heredoc indented under the schema
  # block. Every definition Postgres renders starts at column 0, so the heredoc
  # strips exactly the four spaces added here and a function body comes back
  # byte-for-byte. The quoted delimiter keeps Ruby from interpolating `#{`. A body
  # with a line that would end the heredoc early falls back to a string literal.
  def self.execute_statement(sql)
    sql = sql.strip
    return "  execute #{sql.inspect}" if sql.each_line.any? { |line| line.strip == HEREDOC }

    body = sql.each_line.map { |line| line.chomp.empty? ? "" : "    #{line.chomp}" }.join("\n")
    "  execute <<~'#{HEREDOC}'\n#{body}\n  #{HEREDOC}"
  end

  private

  def trailer(stream)
    statements = functions_and_triggers
    if statements.any?
      stream.puts
      stream.puts "  # Functions and triggers, which the Ruby schema format has no DSL for. Dumped"
      stream.puts "  # as the SQL Postgres reports — see"
      stream.puts "  # config/initializers/schema_dump_functions_and_triggers.rb."
      statements.each_with_index do |sql, index|
        stream.puts if index.positive?
        stream.puts SchemaDumpFunctionsAndTriggers.execute_statement(sql)
      end
    end

    super
  end

  # Functions first: a trigger names its function, and both come after every
  # table, since a trigger names its table too.
  def functions_and_triggers
    schemas = @connection.quote(@dump_schemas.join(","))

    functions = @connection.select_values(format(FUNCTIONS, schemas:), "SCHEMA")
    triggers = @connection.select_rows(format(TRIGGERS, schemas:), "SCHEMA")
      .reject { |table, _| ignored?(table) }
      .map(&:last)

    functions + triggers
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(SchemaDumpFunctionsAndTriggers)
end
