require "test_helper"

class ProcessRegistryTest < ActiveSupport::TestCase
  setup do
    @registry = ProcessRegistry.new
  end

  # === Tests for ProcessInfo struct ===

  test "ProcessInfo has expected attributes" do
    info = ProcessRegistry::ProcessInfo.new(
      pid: 12345,
      uid: 501,
      gid: 20,
      command: "echo hello",
      correlation_id: "abc123",
      spawned_at: Time.current,
      working_directory: "/tmp",
      process_group: 12345
    )

    assert_equal 12345, info.pid
    assert_equal 501, info.uid
    assert_equal 20, info.gid
    assert_equal "echo hello", info.command
    assert_equal "abc123", info.correlation_id
    assert_equal "/tmp", info.working_directory
    assert_equal 12345, info.process_group
  end

  test "ProcessInfo#to_h returns hash representation" do
    info = ProcessRegistry::ProcessInfo.new(
      pid: 12345,
      uid: 501,
      gid: 20,
      command: "test",
      correlation_id: "abc",
      spawned_at: Time.current,
      working_directory: "/tmp",
      process_group: 12345
    )

    hash = info.to_h
    assert_kind_of Hash, hash
    assert_equal 12345, hash[:pid]
    assert_equal 501, hash[:uid]
    assert_equal "test", hash[:command]
  end

  test "ProcessInfo#owned_by? checks ownership" do
    info = ProcessRegistry::ProcessInfo.new(
      pid: 12345,
      uid: 501,
      gid: 20,
      command: "test",
      correlation_id: "abc",
      spawned_at: Time.current,
      working_directory: nil,
      process_group: 12345
    )

    assert info.owned_by?(501)
    assert_not info.owned_by?(0)
  end

  test "ProcessInfo#age_seconds returns process age" do
    spawn_time = 10.seconds.ago
    info = ProcessRegistry::ProcessInfo.new(
      pid: 12345,
      uid: 501,
      gid: 20,
      command: "test",
      correlation_id: "abc",
      spawned_at: spawn_time,
      working_directory: nil,
      process_group: 12345
    )

    assert_in_delta 10, info.age_seconds, 1
  end

  # === Tests for register method ===

  test "register adds process to registry" do
    info = @registry.register(12345, command: "test-command")

    assert_instance_of ProcessRegistry::ProcessInfo, info
    assert_equal 12345, info.pid
    assert_equal "test-command", info.command
  end

  test "register uses current uid and gid as defaults" do
    info = @registry.register(12345, command: "test")

    assert_equal Process.uid, info.uid
    assert_equal Process.gid, info.gid
  end

  test "register generates correlation_id if not provided" do
    info = @registry.register(12345, command: "test")

    assert_not_nil info.correlation_id
    assert_match(/\A[0-9a-f-]+\z/, info.correlation_id)
  end

  test "register uses provided correlation_id" do
    info = @registry.register(12345, command: "test", correlation_id: "custom-id")

    assert_equal "custom-id", info.correlation_id
  end

  test "register normalizes array command to string" do
    info = @registry.register(12345, command: [ "echo", "hello", "world" ])

    assert_equal "echo hello world", info.command
  end

  test "register sets spawned_at to current time" do
    freeze_time do
      info = @registry.register(12345, command: "test")
      assert_equal Time.current, info.spawned_at
    end
  end

  test "register sets process_group to pid if not provided" do
    info = @registry.register(12345, command: "test")

    assert_equal 12345, info.process_group
  end

  test "register uses provided process_group" do
    info = @registry.register(12345, command: "test", process_group: 99999)

    assert_equal 99999, info.process_group
  end

  # === Tests for get method ===

  test "get returns registered process info" do
    @registry.register(12345, command: "test")
    info = @registry.get(12345)

    assert_not_nil info
    assert_equal 12345, info.pid
  end

  test "get returns nil for unregistered pid" do
    info = @registry.get(99999)

    assert_nil info
  end

  # === Tests for unregister method ===

  test "unregister removes process from registry" do
    @registry.register(12345, command: "test")
    removed = @registry.unregister(12345)

    assert_not_nil removed
    assert_equal 12345, removed.pid
    assert_nil @registry.get(12345)
  end

  test "unregister returns nil for unregistered pid" do
    removed = @registry.unregister(99999)

    assert_nil removed
  end

  # === Tests for all method ===

  test "all returns all registered processes" do
    @registry.register(12345, command: "test1")
    @registry.register(12346, command: "test2")

    all = @registry.all

    assert_equal 2, all.size
    assert all.key?(12345)
    assert all.key?(12346)
  end

  test "all returns a copy to prevent modification" do
    @registry.register(12345, command: "test")
    all = @registry.all
    all.delete(12345)

    assert_not_nil @registry.get(12345)
  end

  # === Tests for count method ===

  test "count returns number of registered processes" do
    assert_equal 0, @registry.count

    @registry.register(12345, command: "test1")
    assert_equal 1, @registry.count

    @registry.register(12346, command: "test2")
    assert_equal 2, @registry.count
  end

  # === Tests for registered? method ===

  test "registered? returns true for registered process" do
    @registry.register(12345, command: "test")

    assert @registry.registered?(12345)
  end

  test "registered? returns false for unregistered process" do
    assert_not @registry.registered?(99999)
  end

  # === Tests for owned_by method ===

  test "owned_by returns processes owned by specific user" do
    @registry.register(12345, command: "test1", uid: 501)
    @registry.register(12346, command: "test2", uid: 501)
    @registry.register(12347, command: "test3", uid: 0)

    owned = @registry.owned_by(501)

    assert_equal 2, owned.size
    assert owned.all? { |info| info.uid == 501 }
  end

  test "owned_by returns empty array when no matching processes" do
    @registry.register(12345, command: "test", uid: 501)

    owned = @registry.owned_by(999)

    assert_empty owned
  end

  # === Tests for by_correlation_id method ===

  test "by_correlation_id returns processes with matching correlation_id" do
    @registry.register(12345, command: "test1", correlation_id: "session-1")
    @registry.register(12346, command: "test2", correlation_id: "session-1")
    @registry.register(12347, command: "test3", correlation_id: "session-2")

    matches = @registry.by_correlation_id("session-1")

    assert_equal 2, matches.size
    assert matches.all? { |info| info.correlation_id == "session-1" }
  end

  # === Tests for clear method ===

  test "clear removes all processes and returns count" do
    @registry.register(12345, command: "test1")
    @registry.register(12346, command: "test2")

    count = @registry.clear

    assert_equal 2, count
    assert_equal 0, @registry.count
  end

  # === Tests for older_than method ===

  test "older_than returns processes older than threshold" do
    # Register an old process
    old_time = 120.seconds.ago
    @registry.register(12345, command: "old")
    # Manually update spawned_at
    @registry.get(12345).spawned_at = old_time

    # Register a recent process
    @registry.register(12346, command: "new")

    old_processes = @registry.older_than(60)

    assert_equal 1, old_processes.size
    assert_equal 12345, old_processes.first.pid
  end

  # === Tests for thread safety ===

  test "registry is thread-safe for concurrent access" do
    threads = 10.times.map do |i|
      Thread.new do
        pid = 10000 + i
        @registry.register(pid, command: "test-#{i}")
        sleep 0.01
        @registry.get(pid)
        @registry.unregister(pid)
      end
    end

    assert_nothing_raised { threads.each(&:join) }
  end
end
