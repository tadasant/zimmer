# frozen_string_literal: true

require "test_helper"

class ClaudeCredentialStoreTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("claude-credential-store-test")
    @path = File.join(@dir, ".credentials.json")
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "read returns an empty hash when the store is missing" do
    assert_equal({}, ClaudeCredentialStore.read(@path))
  end

  test "read returns an empty hash for corrupt JSON" do
    File.write(@path, "{not json")

    assert_equal({}, ClaudeCredentialStore.read(@path))
  end

  test "read returns an empty hash for a non-object top-level value" do
    File.write(@path, JSON.generate([ "unexpected" ]))

    assert_equal({}, ClaudeCredentialStore.read(@path))
  end

  test "read parses the stored object" do
    File.write(@path, JSON.generate({ "claudeAiOauth" => { "accessToken" => "a" } }))

    assert_equal "a", ClaudeCredentialStore.read(@path).dig("claudeAiOauth", "accessToken")
  end

  test "write_atomically leaves owner-only permissions and no temp file behind" do
    ClaudeCredentialStore.write_atomically(@path, { "claudeAiOauth" => { "accessToken" => "a" } })

    assert_equal "a", JSON.parse(File.read(@path)).dig("claudeAiOauth", "accessToken")
    assert_equal "600", format("%o", File.stat(@path).mode & 0o777)
    assert_equal [ File.basename(@path) ], Dir.children(@dir).grep_v(/\.lock\z/)
  end

  test "write_atomically creates the credentials directory" do
    nested = File.join(@dir, "nested", ".credentials.json")

    ClaudeCredentialStore.write_atomically(nested, { "a" => 1 })

    assert File.exist?(nested)
  end

  test "with_lock serializes writers that address the same credentials file" do
    # Both Zimmer writers of ~/.claude/.credentials.json take this lock, so a
    # second holder must wait rather than merge into a stale snapshot.
    entered = Queue.new
    release = Queue.new
    second_entered = Queue.new

    first = Thread.new do
      ClaudeCredentialStore.with_lock(@path) do
        entered << true
        release.pop
      end
    end
    entered.pop

    second = Thread.new do
      ClaudeCredentialStore.with_lock(@path) { second_entered << true }
    end

    sleep 0.1
    assert_raises(ThreadError, "the second writer must not enter while the first holds the lock") do
      second_entered.pop(true)
    end

    release << true
    first.join(5)
    second.join(5)

    assert_equal true, second_entered.pop(true)
  end

  test "with_lock creates the credentials directory and its lock file" do
    nested = File.join(@dir, "nested", ".credentials.json")

    ClaudeCredentialStore.with_lock(nested) { nil }

    assert File.exist?(File.join(@dir, "nested", ClaudeCredentialStore::LOCK_FILENAME))
  end
end
