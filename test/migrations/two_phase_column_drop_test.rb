# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# CI wiring, and the behavioural spec, for TwoPhaseColumnDropGuard — the guard
# behind "Dropping a column takes two deploys"
# (docs/src/content/docs/operate/deploying.md). The guard itself is Rails-free;
# only the `ignored_columns` assertion below needs a booted app.
class TwoPhaseColumnDropTest < ActiveSupport::TestCase
  test "no migration drops a column without evidence that phase 1 shipped" do
    violations = TwoPhaseColumnDropGuard.violations

    assert_empty violations, TwoPhaseColumnDropGuard.report(violations)
  end

  # Without this, deleting or squashing a grandfathered migration would leave a
  # dead name behind, and that list is the only thing standing between the guard
  # and the six drops it deliberately tolerates.
  test "every grandfathered migration still exists and still drops a column" do
    still_dropping = TwoPhaseColumnDropGuard.scan_directory.map(&:basename)

    assert_empty TwoPhaseColumnDropGuard::GRANDFATHERED - still_dropping,
      "GRANDFATHERED names migrations that no longer drop a column in the forward " \
      "direction (or no longer exist). Remove them from the list."
  end

  # The other half of the convention: deploy 2 drops the column AND removes the
  # `ignored_columns` entry. An entry naming a column that is already gone is a
  # phase-2 cleanup that was forgotten — harmless today, and a silent trap the
  # next time a column of that name is added back.
  test "no ignored_columns entry names a column that has already been dropped" do
    Rails.application.eager_load!

    stale = ApplicationRecord.descendants.flat_map do |model|
      next [] if model.abstract_class? || model.ignored_columns.empty?
      next [] unless model.table_exists?

      actual = model.connection_pool.with_connection { |c| c.columns(model.table_name).map(&:name) }
      (model.ignored_columns.map(&:to_s) - actual).map { |column| "#{model.name}.ignored_columns: #{column}" }
    end

    assert_empty stale,
      "These columns are already dropped, so the `ignored_columns` entry is dead weight — " \
      "deploy 2 of a two-phase drop removes it along with the column:\n  #{stale.join("\n  ")}"
  end

  test "the shipped single-phase drop of blocked_by_session_id is what this guard catches" do
    # Not a fixture: the real migration, unmodified, still on disk. It is the
    # incident, and the guard would be worth nothing if it did not flag it.
    result = TwoPhaseColumnDropGuard.scan_file(
      File.join(TwoPhaseColumnDropGuard::MIGRATION_DIR,
        "20260815100000_drop_blocked_by_session_from_sessions.rb")
    )

    assert result.drops_columns?
    assert_equal [ "remove_reference :sessions, :blocked_by_session, index: true" ],
      result.removals.map(&:source)
    assert_not result.annotation_names_a_ref?
    assert_includes TwoPhaseColumnDropGuard.report([ result ]), "phase 2 of #474"
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

    assert result.drops_columns?
    assert result.annotation_names_a_ref?
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

    assert result.annotated?
    assert_not result.annotation_names_a_ref?
  end

  test "removals in the reverse direction are not drops" do
    result = scan_source(<<~RUBY)
      class AddWidgetToSessions < ActiveRecord::Migration[8.0]
        def up
          add_column :sessions, :widget, :string
        end

        def down
          remove_column :sessions, :widget
        end
      end
    RUBY

    assert_not result.drops_columns?
  end

  test "removals inside reversible's down branch and inside revert are not drops" do
    result = scan_source(<<~RUBY)
      class AddWidgetToSessions < ActiveRecord::Migration[8.0]
        def change
          add_column :sessions, :widget, :string

          reversible do |dir|
            dir.down { remove_column :sessions, :gadget }
          end

          revert { remove_column :sessions, :gizmo }
        end
      end
    RUBY

    assert_not result.drops_columns?
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

    assert_equal 6, result.removals.size
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

  private

  def scan_source(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "20260101000000_scanned.rb")
      File.write(path, source)
      TwoPhaseColumnDropGuard.scan_file(path)
    end
  end
end
