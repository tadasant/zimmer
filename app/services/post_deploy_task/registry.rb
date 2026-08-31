# frozen_string_literal: true

# Finds the one-time post-deploy tasks on disk.
#
# Deliberately the same shape as `db/migrate`: a directory of timestamp-prefixed
# files, each defining one class, discovered by listing rather than by a manifest
# somebody has to remember to edit. A manifest is a second place to get it wrong,
# and a task that is silently not registered is exactly the failure this
# mechanism exists to remove.
#
# The files are NOT autoloaded — `db/` is not an autoload path, and these classes
# must not be eager-loaded into every process — so `entry.task_class` loads the
# file the same way `ActiveRecord::MigrationProxy` does.
class PostDeployTask
  module Registry
    DEFAULT_ROOT = Rails.root.join("db/post_deploy")

    # `20260830100500_prune_orphaned_widgets.rb`. The timestamp is 14 digits, as
    # migrations use, so the two sort together and a developer can copy the habit.
    FILENAME = /\A(\d{14})_([a-z0-9_]+)\.rb\z/

    class InvalidTask < StandardError; end

    Entry = Struct.new(:version, :basename, :path, keyword_init: true) do
      def task_name = basename.camelize

      # Loads the file and returns the class. `load`, not `require`: in
      # development the file may be edited between ticks, and a task that ran the
      # version from the last boot would be a genuinely confusing bug.
      #
      # The copy left by an earlier tick is removed first. Reopening it would
      # bind the new definition to the class object that was `PostDeployTask`
      # when it was first loaded — and in development Rails reloads that
      # superclass, so the second tick after an edit anywhere in `app/` would
      # raise `TypeError: superclass mismatch`. Removing also keeps a task's own
      # constants from warning about redefinition on every tick.
      #
      # Only a previous copy of a task is removed, never an unrelated constant
      # that happens to share the name: that case still reaches `load` and fails
      # loudly, which is the right outcome for a genuine name collision.
      def task_class
        forget_previous_copy
        load path

        klass = task_name.safe_constantize
        unless klass.is_a?(Class) && klass < PostDeployTask
          raise InvalidTask, "#{path} must define #{task_name} < PostDeployTask"
        end

        klass
      end

      private

      def forget_previous_copy
        return unless Object.const_defined?(task_name, false)

        existing = Object.const_get(task_name, false)
        # Compared by NAME, not identity: after a reload the ancestor is a
        # different object with the same name, which is exactly the case this
        # exists to clear.
        return unless existing.is_a?(Class) && existing.ancestors.any? { |a| a.name == "PostDeployTask" }

        Object.send(:remove_const, task_name)
      end
    end

    module_function

    # Every task on disk, oldest first. Ordering is by version, and the runner
    # honours it — but it is not a barrier: a task that fails does not hold up
    # the ones behind it. A task that genuinely depends on an earlier one should
    # check for what it needs rather than trusting the order.
    def all(root: DEFAULT_ROOT)
      return [] unless File.directory?(root)

      entries = Dir.children(root).filter_map do |filename|
        match = FILENAME.match(filename)
        next unless match

        Entry.new(version: match[1], basename: match[2], path: File.join(root, filename))
      end.sort_by(&:version)

      assert_unique!(entries)
      entries
    end

    def find(version, root: DEFAULT_ROOT)
      all(root: root).find { |entry| entry.version == version }
    end

    # Two files sharing a version would share a ledger row, so the second would
    # be recorded as run without ever running. Two sharing a class name would
    # have the second `load` silently reopen the first. Both are cheap to detect
    # and impossible to debug from the symptom, so they raise here — and
    # `test/services/post_deploy_task/registry_test.rb` runs this over the real
    # directory, which makes it a CI failure rather than a production one.
    def assert_unique!(entries)
      %i[version task_name].each do |attribute|
        duplicated = entries.group_by { |e| e.public_send(attribute) }.select { |_, v| v.size > 1 }
        next if duplicated.empty?

        raise InvalidTask, "duplicate post-deploy task #{attribute}: " \
          "#{duplicated.map { |value, dupes| "#{value} (#{dupes.map(&:path).join(', ')})" }.join('; ')}"
      end
    end
  end
end
