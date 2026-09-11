# frozen_string_literal: true

# The Postgres half of GateDecision's append-only guarantee, which
# CreateGateDecisions had to leave out (https://github.com/tadasant/zimmer/issues/780).
#
# The model's `before_update` / `before_destroy` callbacks refuse every path that
# goes through an instance. `update_all`, `delete_all`, `update_column` and raw SQL
# never reach a callback; this trigger is what refuses those.
#
# It could not ship with the table because db/schema.rb is a Ruby dump, and the
# Ruby dumper has no way to write a trigger or a function down: a trigger installed
# here would have existed in production and silently not existed in CI, in test,
# or in anything rebuilt with `db:schema:load`. The dump now carries functions and
# triggers (config/initializers/schema_dump_functions_and_triggers.rb), and
# `db:schema:verify` fails any migration that builds an object a schema load
# does not reproduce.
#
# ONE UPDATE IS ALLOWED. `writing_session_id` is a foreign key with
# ON DELETE SET NULL, so deleting a session updates every row it wrote, clearing
# that column. Refusing it would make the session undeletable. The trigger lets an
# UPDATE through only when `writing_session_id` ends up NULL and no other column
# changed.
#
# TRUNCATE is not covered. It fires no row trigger, and it is already refused
# while any GateDecisionFeedback row points at the table, because that foreign key
# has no ON DELETE action.
class AddAppendOnlyTriggerToGateDecisions < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION gate_decisions_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'UPDATE'
           AND NEW.writing_session_id IS NULL
           AND (to_jsonb(NEW) - 'writing_session_id') = (to_jsonb(OLD) - 'writing_session_id') THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'gate_decisions is append-only: % of row % refused', TG_OP, OLD.id
          USING HINT = 'Record a new decision citing the one it corrects.';
      END;
      $$
    SQL

    execute <<~SQL
      CREATE TRIGGER gate_decisions_append_only
      BEFORE UPDATE OR DELETE ON gate_decisions
      FOR EACH ROW EXECUTE FUNCTION gate_decisions_append_only()
    SQL
  end

  def down
    execute "DROP TRIGGER gate_decisions_append_only ON gate_decisions"
    execute "DROP FUNCTION gate_decisions_append_only()"
  end
end
