require "test_helper"

class ProcessManagerTest < ActiveSupport::TestCase
  test "base class spawn raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.spawn("echo", "test")
    end
  end

  test "base class spawn_with_tracking raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.spawn_with_tracking("echo", "test", correlation_id: "abc123")
    end
  end

  test "base class wait raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.wait(12345)
    end
  end

  test "base class kill raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.kill("TERM", 12345)
    end
  end

  test "base class kill_process_group raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.kill_process_group("TERM", 12345)
    end
  end

  test "base class running? raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.running?(12345)
    end
  end

  test "base class getpgid raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.getpgid(12345)
    end
  end

  test "base class get_tracked_process raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.get_tracked_process(12345)
    end
  end

  test "base class tracked_processes raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.tracked_processes
    end
  end

  test "base class untrack_process raises NotImplementedError" do
    manager = ProcessManager.new
    assert_raises(NotImplementedError) do
      manager.untrack_process(12345)
    end
  end
end
