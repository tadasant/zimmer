# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# CI wiring, and the behavioural spec, for TwoPhaseColumnDropGuard — the guard
# behind "Dropping a column takes two deploys" and "Renames and table drops
# expand before they contract"
# (docs/src/content/docs/operate/deploying.md). The guard itself is Rails-free
# and the `lint` job runs it directly; only the `ignored_columns` assertion
# below needs a booted app.
class TwoPhaseColumnDropTest < ActiveSupport::TestCase
  test "no migration drops or renames without evidence that the earlier phase shipped" do
    violations = TwoPhaseColumnDropGuard.violations

    assert_empty violations, TwoPhaseColumnDropGuard.report(violations)
  end

  # Two ways the grandfather list could quietly widen the hole it exists to
  # narrow: a name left behind after its migration was deleted or squashed, and
  # a seventh entry added instead of doing the two deploys.
  test "the grandfather list is honest and closed" do
    still_hazardous = TwoPhaseColumnDropGuard.scan_directory.map(&:basename)

    assert_empty TwoPhaseColumnDropGuard::GRANDFATHERED - still_hazardous,
      "GRANDFATHERED names migrations that no longer drop or rename in the forward " \
      "direction (or no longer exist). Remove them from the list."

    added_since = TwoPhaseColumnDropGuard::GRANDFATHERED
      .select { |name| name[/\A\d{14}/] >= TwoPhaseColumnDropGuard::GRANDFATHER_CUTOFF }

    assert_empty added_since,
      "These postdate the guard, so they were never grandfathered — they are new drops " \
      "or renames that belong in separate deploys, with the annotation their shape calls for."
  end

  # The other half of the convention: deploy 2 drops the column AND removes the
  # `ignored_columns` entry. An entry naming a column that is already gone is a
  # phase-2 cleanup that was forgotten — harmless today, and a silent trap the
  # next time a column of that name is added back.
  test "no ignored_columns entry names a column that has already been dropped" do
    # `abstract_class?` and `ignored_columns` are checked before `table_exists?`
    # so an anonymous ApplicationRecord subclass left behind by another test in
    # this worker short-circuits before anything touches `table_name`.
    models = ApplicationRecord.descendants
      .reject { |model| model.abstract_class? || model.ignored_columns.empty? || !model.table_exists? }

    stale = TwoPhaseColumnDropGuard.stale_ignored_columns(models) do |model|
      model.connection_pool.with_connection { |c| c.columns(model.table_name).map(&:name) }
    end

    assert_empty stale,
      "These columns are already dropped, so the `ignored_columns` entry is dead weight — " \
      "deploy 2 of a two-phase drop removes it along with the column:\n  #{stale.join("\n  ")}"
  end

  # The assertion above went live when `Session` ignored `execution_provider` for
  # phase 1 of #172, and goes vacuous again the moment that entry comes out. So the
  # detection is pinned here against a stub instead, where it holds either way.
  test "stale_ignored_columns reports an entry whose column is gone, and not one mid-phase-1" do
    model = Struct.new(:name, :ignored_columns).new("Session", %w[blocked_by_session_id])

    mid_phase_one = TwoPhaseColumnDropGuard.stale_ignored_columns([ model ]) do
      %w[id blocked_by_session_id]
    end
    assert_empty mid_phase_one

    forgotten = TwoPhaseColumnDropGuard.stale_ignored_columns([ model ]) { %w[id] }
    assert_equal [ "Session.ignored_columns: blocked_by_session_id" ], forgotten
  end

  test "the shipped single-phase drop of blocked_by_session_id is what this guard catches" do
    # Not a fixture: the real migration, unmodified, still on disk. It is the
    # incident, and the guard would be worth nothing if it did not flag it.
    result = TwoPhaseColumnDropGuard.scan_file(
      File.join(TwoPhaseColumnDropGuard::MIGRATION_DIR,
        "20260815100000_drop_blocked_by_session_from_sessions.rb")
    )

    assert result.hazardous?
    assert_equal [ :column_drop ], result.shapes
    assert_equal [ "remove_reference :sessions, :blocked_by_session, index: true" ],
      result.hazards.map(&:source)
    assert_not result.proven?(:two_phase_drop)
    assert_includes TwoPhaseColumnDropGuard.report([ result ]), "phase 2 of #474"
  end

  # The rename half of the same argument, and the reason zimmer#722 exists: this
  # one shipped three column renames in a single deploy and the guard, as it
  # stood, said nothing. It is grandfathered, so it is not a violation — but it
  # is a hazard, and the widened guard has to see it.
  test "the shipped single-phase rename of stop_condition is what the widened guard catches" do
    result = TwoPhaseColumnDropGuard.scan_file(
      File.join(TwoPhaseColumnDropGuard::MIGRATION_DIR,
        "20260503180000_rename_stop_condition_to_goal.rb")
    )

    assert_equal [ :column_rename ], result.shapes
    assert_equal 3, result.hazards.size
    assert_not result.proven?(:expand_contract)
    assert_includes TwoPhaseColumnDropGuard::GRANDFATHERED, result.basename
  end

  test "an annotated phase-2 migration passes" do
    result = scan_source(<<~RUBY)
      # two-phase-drop: phase 2 of #474
      class DropWidgetFromSessions < ActiveRecord::Migration[8.0]
        def up
          remove_column :sessions, :widget
        end
      end
    RUBY

    assert result.hazardous?
    assert result.proven?(:two_phase_drop)
  end

  test "an annotation that names nothing does not count as evidence" do
    result = scan_source(<<~RUBY)
      # two-phase-drop: phase 2 of the earlier PR
      class DropWidgetFromSessions < ActiveRecord::Migration[8.0]
        def up
          remove_column :sessions, :widget
        end
      end
    RUBY

    assert result.annotated?(:two_phase_drop)
    assert_not result.proven?(:two_phase_drop)
  end

  test "a real annotation still counts when a vaguer one comes first" do
    result = scan_source(<<~RUBY)
      # two-phase-drop: phase 2 of the earlier PR
      # two-phase-drop: phase 2 of #474
      class DropWidgetFromSessions < ActiveRecord::Migration[8.0]
        def up
          remove_column :sessions, :widget
        end
      end
    RUBY

    assert result.proven?(:two_phase_drop)
  end

  test "an annotation inside a string is not a comment and is not evidence" do
    result = scan_source(<<~'RUBY')
      class DropWidgetFromSessions < ActiveRecord::Migration[8.0]
        def up
          execute <<~SQL
            -- two-phase-drop: phase 2 of #474
            ALTER TABLE sessions DROP COLUMN widget;
          SQL
        end
      end
    RUBY

    assert result.hazardous?
    assert_not result.annotated?(:two_phase_drop)
  end

  test "removals in the reverse direction are not drops" do
    result = scan_source(<<~RUBY)
      class AddWidgetToSessions < ActiveRecord::Migration[8.0]
        def up
          add_column :sessions, :widget, :string
        end

        def down
          remove_column :sessions, :widget
          rename_column :sessions, :gizmo, :gadget
          drop_table :widgets
          execute "ALTER TABLE sessions DROP COLUMN gadget"
          execute "ALTER TABLE gadgets RENAME TO widgets"
        end
      end
    RUBY

    assert_not result.hazardous?
  end

  test "removals inside reversible's down branch and inside revert are not drops" do
    result = scan_source(<<~RUBY)
      class AddWidgetToSessions < ActiveRecord::Migration[8.0]
        def change
          add_column :sessions, :widget, :string

          reversible do |dir|
            dir.down { remove_column :sessions, :gadget }
          end

          revert { rename_column :sessions, :gizmo, :doohickey }
        end
      end
    RUBY

    assert_not result.hazardous?
  end

  test "every spelling of a forward drop is caught" do
    result = scan_source(<<~RUBY)
      class DropEverything < ActiveRecord::Migration[8.0]
        def change
          remove_column :sessions, :widget
          remove_columns :sessions, :gadget, :gizmo
          remove_reference :sessions, :blocked_by_session
          remove_belongs_to :sessions, :owner
          change_table :sessions, bulk: true do |t|
            t.remove :doohickey
          end
          execute "ALTER TABLE sessions DROP COLUMN thingamajig"
        end
      end
    RUBY

    assert_equal 6, result.hazards.size
    assert_equal [ :column_drop ], result.shapes
  end

  # A heredoc is how anyone actually writes raw SQL in a migration, and Prism's
  # call-node slice stops at the `<<~SQL` marker — so matching the *call* source
  # would miss every realistic one.
  test "a heredoc DROP COLUMN is caught, at the line it is written on" do
    result = scan_source(<<~'RUBY')
      class DropWidgetFromSessions < ActiveRecord::Migration[8.0]
        def up
          execute <<~SQL.squish
            ALTER TABLE sessions
              DROP COLUMN widget
          SQL
        end
      end
    RUBY

    assert_equal 1, result.hazards.size
    assert_equal 5, result.hazards.first.line
    assert_equal "DROP COLUMN widget", result.hazards.first.source
  end

  test "violations names the unannotated drop and clears once it is annotated" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "20260101000000_add_widget.rb"), <<~RUBY)
        class AddWidget < ActiveRecord::Migration[8.0]
          def change
            add_column :sessions, :widget, :string
          end
        end
      RUBY
      drop = File.join(dir, "20260101000001_drop_widget.rb")
      File.write(drop, <<~RUBY)
        class DropWidget < ActiveRecord::Migration[8.0]
          def up
            remove_column :sessions, :widget
          end
        end
      RUBY

      assert_equal [ "20260101000001_drop_widget.rb" ],
        TwoPhaseColumnDropGuard.violations(dir).map(&:basename)

      File.write(drop, "# two-phase-drop: phase 2 of #999\n#{File.read(drop)}")

      assert_empty TwoPhaseColumnDropGuard.violations(dir)
    end
  end

  test "every spelling of a forward rename or table change is caught, with its shape" do
    result = scan_source(<<~RUBY)
      class RenameEverything < ActiveRecord::Migration[8.0]
        def change
          rename_column :sessions, :widget, :gadget
          rename_table :widgets, :gadgets
          drop_table :gizmos
          change_table :sessions, bulk: true do |t|
            t.rename :doohickey, :thingamajig
          end
          execute "ALTER TABLE sessions RENAME COLUMN alpha TO beta"
          execute "ALTER TABLE alphas RENAME TO betas"
          execute "DROP TABLE gammas"
        end
      end
    RUBY

    assert_equal(
      { column_rename: 3, table_rename: 2, table_drop: 2 },
      result.hazards.group_by(&:shape).transform_values(&:size)
    )
  end

  # `t.rename` follows `t.remove`: a receiver is what makes it a schema change.
  # A bare `rename` or `remove` is something else entirely.
  test "a receiverless rename or remove is not a schema change" do
    result = scan_source(<<~RUBY)
      class NotAMigrationReally < ActiveRecord::Migration[8.0]
        def change
          rename "a", "b"
          remove :widget
        end
      end
    RUBY

    assert_not result.hazardous?
  end

  # An index carries no attribute and no query of the old container names it, so
  # neither of these strands anything mid-swap.
  test "index churn is not a schema change the old containers can see" do
    result = scan_source(<<~RUBY)
      class ShuffleIndexes < ActiveRecord::Migration[8.0]
        def change
          rename_index :sessions, :index_old, :index_new
          remove_index :sessions, :widget
        end
      end
    RUBY

    assert_not result.hazardous?
  end

  test "a rename takes the expand-contract annotation, and the drop annotation does not cover it" do
    wrong = scan_source(<<~RUBY)
      # two-phase-drop: phase 2 of #474
      class RenameWidget < ActiveRecord::Migration[8.0]
        def change
          rename_column :sessions, :widget, :gadget
        end
      end
    RUBY

    assert_equal 1, wrong.unproven_hazards.size

    right = scan_source(<<~RUBY)
      # expand-contract: contract of #474
      class RenameWidget < ActiveRecord::Migration[8.0]
        def change
          rename_column :sessions, :widget, :gadget
        end
      end
    RUBY

    assert right.hazardous?
    assert_empty right.unproven_hazards
  end

  test "an expand-contract annotation that names nothing does not count as evidence" do
    result = scan_source(<<~RUBY)
      # expand-contract: contract of the earlier PR
      class DropWidgets < ActiveRecord::Migration[8.0]
        def up
          drop_table :widgets
        end
      end
    RUBY

    assert result.annotated?(:expand_contract)
    assert_not result.proven?(:expand_contract)
    assert_equal 1, result.unproven_hazards.size
  end

  # A migration that renames one column and drops another needs both recipes,
  # and one annotation clears only its own half.
  test "each shape is annotated on its own, and the report names the ones still unproven" do
    result = scan_source(<<~RUBY)
      # two-phase-drop: phase 2 of #474
      class MixedBag < ActiveRecord::Migration[8.0]
        def up
          remove_column :sessions, :widget
          rename_column :sessions, :gadget, :gizmo
        end
      end
    RUBY

    assert_equal [ :column_rename ], result.unproven_hazards.map(&:shape)

    report = TwoPhaseColumnDropGuard.report([ result ])
    assert_includes report, "renames a column in the forward direction"
    assert_not_includes report, "drops a column in the forward direction"
  end

  test "each shape's failure message points at its own recipe" do
    messages = {
      "rename_column :sessions, :a, :b" =>
        [ "renames a column in the forward direction", "expand-contract: contract of" ],
      "rename_table :widgets, :gadgets" =>
        [ "renames a table in the forward direction", "expand-contract: contract of" ],
      "drop_table :widgets" =>
        [ "drops a table in the forward direction", "expand-contract: contract of" ],
      "remove_column :sessions, :widget" =>
        [ "drops a column in the forward direction", "two-phase-drop: phase 2 of" ]
    }

    messages.each do |call, (headline, annotation)|
      result = scan_source(<<~RUBY)
        class Whatever < ActiveRecord::Migration[8.0]
          def up
            #{call}
          end
        end
      RUBY

      report = TwoPhaseColumnDropGuard.report([ result ])
      assert_includes report, headline
      assert_includes report, annotation
    end
  end

  # The `down` of nearly every `create_table` migration in this repo ends in a
  # `drop_table`, and none of them is a hazard. The guard would be unusable if
  # they were.
  test "the drop_table that closes a create_table's down is not a hazard" do
    result = TwoPhaseColumnDropGuard.scan_file(
      File.join(TwoPhaseColumnDropGuard::MIGRATION_DIR, "20260802120000_create_users.rb")
    )

    assert_not result.hazardous?
  end

  test "a heredoc reports every line it renames on, not just the first" do
    result = scan_source(<<~'RUBY')
      class RenameTwo < ActiveRecord::Migration[8.0]
        def up
          execute <<~SQL
            ALTER TABLE sessions RENAME COLUMN alpha TO beta;
            ALTER TABLE sessions RENAME COLUMN gamma TO delta;
          SQL
        end
      end
    RUBY

    assert_equal [ 4, 5 ], result.hazards.map(&:line)
    assert_equal [ :column_rename, :column_rename ], result.hazards.map(&:shape)
  end

  test "violations names the unannotated rename and clears once it is annotated" do
    Dir.mktmpdir do |dir|
      rename = File.join(dir, "20260101000001_rename_widget.rb")
      File.write(rename, <<~RUBY)
        class RenameWidget < ActiveRecord::Migration[8.0]
          def change
            rename_column :sessions, :widget, :gadget
          end
        end
      RUBY

      assert_equal [ "20260101000001_rename_widget.rb" ],
        TwoPhaseColumnDropGuard.violations(dir).map(&:basename)

      File.write(rename, "# expand-contract: contract of #999\n#{File.read(rename)}")

      assert_empty TwoPhaseColumnDropGuard.violations(dir)
    end
  end

  # `ALTER INDEX … RENAME TO` is how the zero-downtime index swap ends, and the
  # guard's own claim is that index churn is invisible to an old container. A
  # rename shape is only recorded while the statement in scope alters a TABLE.
  test "a raw-SQL rename of anything other than a table is not a hazard" do
    result = scan_source(<<~'RUBY')
      class SwapIndex < ActiveRecord::Migration[8.0]
        def up
          execute "ALTER INDEX index_sessions_on_widget RENAME TO index_sessions_on_gadget"
          execute "ALTER TYPE session_state RENAME TO session_status"
          execute "ALTER SEQUENCE sessions_id_seq RENAME TO sessions_pk_seq"
        end
      end
    RUBY

    assert_not result.hazardous?
  end

  test "an ALTER TABLE spanning lines still renames, and the target does not leak past its string" do
    result = scan_source(<<~'RUBY')
      class RenameAcrossLines < ActiveRecord::Migration[8.0]
        def up
          execute <<~SQL
            ALTER TABLE sessions
              RENAME TO agent_sessions
          SQL
          execute "ALTER INDEX index_sessions_on_widget RENAME TO index_agent_sessions_on_widget"
        end
      end
    RUBY

    assert_equal [ :table_rename ], result.hazards.map(&:shape)
    assert_equal 5, result.hazards.first.line
  end

  # Prism hands an interpolated string to the visitor in fragments, and no
  # fragment of `"… RENAME COLUMN \#{old} TO \#{new}"` satisfies `\w+\s+TO`.
  test "an interpolated raw-SQL column rename is still caught" do
    result = scan_source(<<~'RUBY')
      class RenameDynamically < ActiveRecord::Migration[8.0]
        OLD = "stop_condition"
        NEW = "goal"

        def up
          execute "ALTER TABLE sessions RENAME COLUMN #{OLD} TO #{NEW}"
        end
      end
    RUBY

    assert_equal [ :column_rename ], result.hazards.map(&:shape)
  end

  test "a SQL comment describing a drop is a plan, not a statement" do
    result = scan_source(<<~'RUBY')
      class NotYet < ActiveRecord::Migration[8.0]
        def up
          execute <<~SQL
            -- DROP TABLE legacy_widgets once #123 lands
            -- ALTER TABLE sessions DROP COLUMN widget
            ANALYZE sessions;
          SQL
        end
      end
    RUBY

    assert_not result.hazardous?
  end

  # `t.rename` is matched on its receiver, and the receiver has to be the
  # `change_table` block parameter — a local variable. `File.rename` in a data
  # migration is not a schema change.
  test "a rename on a constant receiver is not a schema change" do
    result = scan_source(<<~RUBY)
      class MoveAFile < ActiveRecord::Migration[8.0]
        def up
          File.rename("/tmp/a", "/tmp/b")
        end
      end
    RUBY

    assert_not result.hazardous?
  end

  private

  def scan_source(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "20260101000000_scanned.rb")
      File.write(path, source)
      TwoPhaseColumnDropGuard.scan_file(path)
    end
  end
end
