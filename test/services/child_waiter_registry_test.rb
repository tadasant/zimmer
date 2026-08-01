# frozen_string_literal: true

require "test_helper"

class ChildWaiterRegistryTest < ActiveSupport::TestCase
  setup do
    @registry = ChildWaiterRegistry.new
    @now = ChildWaiterRegistry.monotonic_now
  end

  test "a freshly claimed pid is live" do
    @registry.claim(4242, command: [ "claude", "--print" ], at: @now)

    assert @registry.live?(4242, stale_after: 300, now: @now)
    assert_equal "claude --print", @registry.waiter(4242).command
  end

  test "the recorded command keeps flag names and drops everything that could be a secret" do
    @registry.claim(
      4242,
      command: [ { "ANTHROPIC_API_KEY" => "sk-secret" }, "/usr/local/bin/claude", "--model", "opus", "-p", "my private prompt" ],
      at: @now
    )

    recorded = @registry.waiter(4242).command

    assert_equal "claude --model -p", recorded
    assert_not_includes recorded, "sk-secret"
    assert_not_includes recorded, "my private prompt"
    assert_not_includes recorded, "opus"
  end

  test "the recorded command drops the value of an inline flag assignment" do
    @registry.claim(4242, command: [ "gh", "--token=ghp_secret" ], at: @now)

    assert_equal "gh --token", @registry.waiter(4242).command
  end

  test "the recorded command is bounded" do
    @registry.claim(4242, command: [ "claude" ] + Array.new(200) { |i| "--flag-#{i}" }, at: @now)

    assert_operator @registry.waiter(4242).command.length, :<=, ChildWaiterRegistry::MAX_COMMAND_LENGTH
  end

  test "a claim with no command records nothing rather than an empty string" do
    @registry.claim(4242, at: @now)

    assert_nil @registry.waiter(4242).command
  end

  test "an unclaimed pid is never live" do
    assert_not @registry.live?(4242, stale_after: 300, now: @now)
    assert_nil @registry.waiter(4242)
  end

  test "a claim whose waiter has gone quiet is not live" do
    @registry.claim(4242, at: @now - 301)

    assert_not @registry.live?(4242, stale_after: 300, now: @now),
      "a claim that has not checked in within the window is orphaned, not live"
  end

  test "heartbeat keeps a long-lived claim live" do
    @registry.claim(4242, at: @now - 3600)
    assert_not @registry.live?(4242, stale_after: 300, now: @now)

    @registry.heartbeat(4242, at: @now - 1)

    assert @registry.live?(4242, stale_after: 300, now: @now),
      "a waiter that keeps calling wait stays protected however old the claim is"
    assert_equal @now - 3600, @registry.waiter(4242).claimed_at, "heartbeat must not rewrite the claim time"
  end

  test "heartbeat upserts an unknown pid so an unclaimed waiter is still protected" do
    @registry.heartbeat(9999, at: @now)

    assert @registry.live?(9999, stale_after: 300, now: @now)
  end

  test "release drops the claim" do
    @registry.claim(4242, at: @now)
    released = @registry.release(4242)

    assert_equal 4242, released.pid
    assert_not @registry.live?(4242, stale_after: 300, now: @now)
    assert_equal 0, @registry.count
  end

  test "prune! forgets claims for pids that no longer exist" do
    @registry.claim(1, at: @now)
    @registry.claim(2, at: @now)
    @registry.claim(3, at: @now)

    gone = @registry.prune!([ 1, 3, 77 ])

    assert_equal [ 2 ], gone
    assert_equal [ 1, 3 ], @registry.all.keys.sort
  end

  test "idle_seconds reports how long the waiter has been quiet" do
    @registry.claim(4242, at: @now - 42)

    assert_in_delta 42, @registry.waiter(4242).idle_seconds(@now), 0.01
  end

  test "instance is process-wide" do
    ChildWaiterRegistry.reset!
    assert_same ChildWaiterRegistry.instance, ChildWaiterRegistry.instance
  ensure
    ChildWaiterRegistry.reset!
  end

  test "concurrent claims and releases do not corrupt the registry" do
    threads = 8.times.map do |i|
      Thread.new do
        100.times do |n|
          pid = (i * 1000) + n
          @registry.claim(pid)
          @registry.heartbeat(pid)
          @registry.release(pid)
        end
      end
    end
    threads.each(&:join)

    assert_equal 0, @registry.count
  end
end
