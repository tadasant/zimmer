# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Guards the per-test AIR catalog warm-up that prevents the
# "unexpected invocation: Open3.capture3(... air resolve ...)" flake — a test
# asserting `Open3.expects(:capture3).never` failing because whichever test drew
# the slot before it in that worker left the catalog cache cold. See
# test/support/air_catalog_cache_warmer.rb for the full rationale.
#
# The assertions here are `AirCatalogService.expects(:load!).never` rather than
# the `Open3.expects(:capture3).never` the flaky test used. They fail on exactly
# the same condition — load! is the only route from a cold cache to the CLI — but
# scope the expectation to this service instead of a process-wide global, which
# is the rule the flaky-test section of docs/operate/testing.md states.
class AirCatalogCacheWarmerTest < ActiveSupport::TestCase
  test "a snapshot of the boot-resolved catalog was captured" do
    assert AirCatalogCacheWarmer.captured?,
      "the boot pre-warm must produce a snapshot, otherwise restore! is a no-op " \
      "and every test is back to inheriting its predecessor's cache"
  end

  test "restore! re-warms a cache a previous test cleared" do
    AirCatalogService.reset!

    AirCatalogCacheWarmer.restore!

    AirCatalogService.expects(:load!).never
    assert AirCatalogService.entries_for(:roots).any?
    assert AirCatalogService.entries_for(:skills).any?
    assert_not AirCatalogService.degraded?,
      "a restored snapshot is real resolve output, not a degraded fallback"
    assert_nil AirCatalogService.resolve_failure
  end

  test "the snapshot is frozen, so one test cannot mutate the catalog every later test sees" do
    assert AirCatalogService.entries_for(:roots).frozen?,
      "an unfrozen shared snapshot would let an in-place mutation poison the rest of the worker, " \
      "beyond the reach of AirCatalogService.reset!"
  end

  # The production flake, reproduced. Committing a write to a card-visible
  # session attribute broadcasts the session card, and
  # sessions/_session_card.html.erb renders Session#agent_root_key ->
  # AgentRootsConfig.find_for_session -> AirCatalogService.entries_for(:roots).
  # On a cold cache that is a real `air resolve` subprocess in the middle of an
  # unrelated test — the exact path GithubCommentPollerJobTest hit at
  # --seed 40537 via GithubCommentPollerJob#persist_comments!.
  test "a session write serves the session-card broadcast from the restored cache" do
    session = sessions(:with_pr_url)
    AirCatalogService.reset!
    AirCatalogCacheWarmer.restore!

    AirCatalogService.expects(:load!).never

    session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/1" ] })
  end
end

# Pins the ordering the fix rests on: the warm-up is declared on
# ActiveSupport::TestCase, and every other test's `setup` — including
# AirCatalogServiceTest's, which clears the cache on purpose — must run after it.
# Nothing else in the suite would notice if a refactor reordered those callbacks;
# it would just go back to failing on an unlucky seed.
#
# Written as its own class because the claim is about what a *subclass* setup
# observes, and this file's other class needs its setup slot for nothing else.
class AirCatalogCacheWarmerOrderingTest < ActiveSupport::TestCase
  setup do
    # Runs after the base-class warm-up, so the catalog is already warm here.
    @catalog_warm_in_setup = AirCatalogService.entries_for(:roots).any?
  end

  test "the base-class warm-up runs before a subclass setup" do
    assert @catalog_warm_in_setup,
      "a subclass setup must observe a warm catalog; if it does not, the warm-up lost its place " \
      "at the head of the callback chain and the AIR-resolve flake is back"
  end

  test "the warm-up is the first setup callback in the chain" do
    first = ActiveSupport::TestCase._setup_callbacks.first
    own = _setup_callbacks.reject { |cb| ActiveSupport::TestCase._setup_callbacks.include?(cb) }

    assert_equal first, _setup_callbacks.first,
      "this class's setup chain must still start with the base-class warm-up"
    assert own.any?, "sanity: this class declares a setup of its own, which must sort after the warm-up"
  end
end
