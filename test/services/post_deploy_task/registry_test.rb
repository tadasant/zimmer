# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class PostDeployTask::RegistryTest < ActiveSupport::TestCase
  def with_tasks(files)
    Dir.mktmpdir do |dir|
      files.each { |name, body| File.write(File.join(dir, name), body) }
      yield dir
    end
  end

  test "finds timestamped task files, oldest first, and ignores everything else" do
    files = {
      "20260102000000_second_task.rb" => "class SecondTask < PostDeployTask; end",
      "20260101000000_first_task.rb" => "class FirstTask < PostDeployTask; end",
      "README.md" => "not a task",
      "no_timestamp.rb" => "class NoTimestamp < PostDeployTask; end",
      "20260103000000_Bad-Name.rb" => "irrelevant"
    }

    with_tasks(files) do |dir|
      entries = PostDeployTask::Registry.all(root: dir)

      assert_equal %w[20260101000000 20260102000000], entries.map(&:version)
      assert_equal %w[FirstTask SecondTask], entries.map(&:task_name)
    end
  end

  test "an absent directory is not an error" do
    assert_empty PostDeployTask::Registry.all(root: Rails.root.join("db/no_such_directory"))
  end

  test "loads the class out of the file" do
    with_tasks("20260104000000_registry_loadable_task.rb" => <<~RUBY) do |dir|
      class RegistryLoadableTask < PostDeployTask
        def up = :done
      end
    RUBY
      entry = PostDeployTask::Registry.all(root: dir).sole
      loaded = entry.task_class

      assert_equal "RegistryLoadableTask", loaded.name
      assert_operator loaded, :<, PostDeployTask
      assert_equal "20260104000000", entry.version
    end
  end

  test "a file that does not define its class is a loud error" do
    with_tasks("20260105000000_wrong_class_name.rb" => "class SomethingElse < PostDeployTask; end") do |dir|
      error = assert_raises(PostDeployTask::Registry::InvalidTask) do
        PostDeployTask::Registry.all(root: dir).sole.task_class
      end

      assert_match(/must define WrongClassName < PostDeployTask/, error.message)
    end
  end

  test "a class that is not a PostDeployTask is a loud error" do
    with_tasks("20260106000000_not_a_task.rb" => "class NotATask; end") do |dir|
      assert_raises(PostDeployTask::Registry::InvalidTask) do
        PostDeployTask::Registry.all(root: dir).sole.task_class
      end
    end
  end

  test "two files sharing a version refuse to resolve" do
    files = {
      "20260107000000_alpha_task.rb" => "class AlphaTask < PostDeployTask; end",
      "20260107000000_beta_task.rb" => "class BetaTask < PostDeployTask; end"
    }

    with_tasks(files) do |dir|
      error = assert_raises(PostDeployTask::Registry::InvalidTask) { PostDeployTask::Registry.all(root: dir) }

      assert_match(/duplicate post-deploy task version/, error.message)
    end
  end

  test "two files sharing a class name refuse to resolve" do
    files = {
      "20260108000000_same_name.rb" => "class SameName < PostDeployTask; end",
      "20260109000000_same_name.rb" => "class SameName < PostDeployTask; end"
    }

    with_tasks(files) do |dir|
      error = assert_raises(PostDeployTask::Registry::InvalidTask) { PostDeployTask::Registry.all(root: dir) }

      assert_match(/duplicate post-deploy task task_name/, error.message)
    end
  end

  test "find locates an entry by version" do
    with_tasks("20260110000000_findable_task.rb" => "class FindableTask < PostDeployTask; end") do |dir|
      assert_equal "FindableTask", PostDeployTask::Registry.find("20260110000000", root: dir).task_name
      assert_nil PostDeployTask::Registry.find("29990101000000", root: dir)
    end
  end

  # The real directory, not a fixture: a task that is on disk and does not load
  # would be discovered on the production box, which is precisely the place this
  # mechanism exists to keep work away from.
  test "every task shipped in db/post_deploy loads and is a PostDeployTask" do
    entries = PostDeployTask::Registry.all

    entries.each do |entry|
      klass = entry.task_class

      assert_operator klass, :<, PostDeployTask, "#{entry.path} must subclass PostDeployTask"
      assert klass.instance_method(:up).owner == klass, "#{entry.path} must define #up"
    end
  end
end
