# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CodexModelResolverTest < ActiveSupport::TestCase
  # The live and bundled outputs of `codex debug models`, cut down to the fields
  # the resolver reads. The live list is what codex-cli 0.146.0 printed for a
  # ChatGPT login whose plan is not offered Sol; the bundled one is the
  # binary's own, including two models it marks as upgraded away.
  LIVE = { "models" => [
    { "slug" => "gpt-reserve", "upgrade" => nil },
    { "slug" => "gpt-5.6-terra", "upgrade" => nil },
    { "slug" => "gpt-5.6-luna", "upgrade" => nil },
    { "slug" => "codex-auto-review", "upgrade" => nil }
  ] }.to_json

  BUNDLED = { "models" => [
    { "slug" => "gpt-5.6-sol", "upgrade" => nil },
    { "slug" => "gpt-5.6-terra", "upgrade" => nil },
    { "slug" => "gpt-5.6-luna", "upgrade" => nil },
    { "slug" => "gpt-5.5", "upgrade" => nil },
    { "slug" => "gpt-5.4", "upgrade" => { "model" => "gpt-5.6-terra" } },
    { "slug" => "gpt-5.4-mini", "upgrade" => { "model" => "gpt-5.6-luna" } }
  ] }.to_json

  setup { CodexModelResolver.catalog_override = nil }

  test "a readable live catalog is the only one consulted, so a family the login is not offered has no slug" do
    ok = Object.new
    BoundedSubprocess.stubs(:run).with([ "codex", "debug", "models" ], anything).returns([ LIVE, "", ok ])
    BoundedSubprocess.stubs(:run).with([ "codex", "debug", "models", "--bundled" ], anything).returns([ BUNDLED, "", ok ])
    SubprocessStatus.stubs(:success?).returns(true)

    assert_equal "gpt-5.6-terra", CodexModelResolver.resolve("terra")
    assert_equal "gpt-5.6-luna", CodexModelResolver.resolve("gpt-5.4-mini")
    assert_nil CodexModelResolver.resolve("sol"), "the bundled gpt-5.6-sol would be refused for this login"
  end

  test "an unreadable live catalog falls back to the bundled one" do
    BoundedSubprocess.stubs(:run).with([ "codex", "debug", "models" ], anything).raises(BoundedSubprocess::TimeoutError)
    BoundedSubprocess.stubs(:run).with([ "codex", "debug", "models", "--bundled" ], anything).returns([ BUNDLED, "", Object.new ])
    SubprocessStatus.stubs(:success?).returns(true)

    assert_equal "gpt-5.6-terra", CodexModelResolver.resolve("terra")
    assert_equal "gpt-5.6-sol", CodexModelResolver.resolve("sol")
  end

  test "a readable live catalog is cached for the full TTL and the bundled one is not read" do
    with_memory_cache do
      BoundedSubprocess.expects(:run).with([ "codex", "debug", "models" ], anything).once.returns([ LIVE, "", Object.new ])
      BoundedSubprocess.expects(:run).with([ "codex", "debug", "models", "--bundled" ], anything).never
      SubprocessStatus.stubs(:success?).returns(true)

      2.times { assert_equal "gpt-5.6-terra", CodexModelResolver.resolve("terra") }
    end
  end

  test "an unreadable live catalog is remembered only briefly" do
    with_memory_cache do
      BoundedSubprocess.stubs(:run).with([ "codex", "debug", "models" ], anything).raises(BoundedSubprocess::TimeoutError)
      BoundedSubprocess.stubs(:run).with([ "codex", "debug", "models", "--bundled" ], anything).returns([ BUNDLED, "", Object.new ])
      SubprocessStatus.stubs(:success?).returns(true)

      assert_equal "gpt-5.6-sol", CodexModelResolver.resolve("sol")
      travel CodexModelResolver::FAILED_LIVE_CACHE_TTL + 1.second do
        BoundedSubprocess.stubs(:run).with([ "codex", "debug", "models" ], anything).returns([ LIVE, "", Object.new ])
        assert_nil CodexModelResolver.resolve("sol"), "the recovered live list is consulted again"
      end
    end
  end

  test "no CLI at all resolves a family to nil, so -m is omitted" do
    BoundedSubprocess.stubs(:run).raises(Errno::ENOENT)

    assert_nil CodexModelResolver.resolve("luna")
  end

  test "newest picks the highest version and ignores other families and suffixes" do
    slugs = %w[gpt-5.6-terra gpt-6-terra gpt-6.1-terra gpt-6.1-terra-pro gpt-6.1-sol gpt-10-luna]

    assert_equal "gpt-6.1-terra", CodexModelResolver.newest(slugs, "terra")
    assert_equal "gpt-6.1-sol", CodexModelResolver.newest(slugs, "sol")
    assert_nil CodexModelResolver.newest(slugs, "astra")
  end

  test "an id that is neither a family nor a legacy id passes through verbatim, and blank stays nil" do
    assert_equal "gpt-9-experimental", CodexModelResolver.resolve("gpt-9-experimental")
    assert_nil CodexModelResolver.resolve(nil)
    assert_nil CodexModelResolver.resolve("")
  end

  private

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end
end
