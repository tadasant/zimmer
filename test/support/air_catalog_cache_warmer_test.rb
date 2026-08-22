# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Guards the per-test AIR catalog warm-up that prevents the
# "unexpected invocation: Open3.capture3(... air resolve ...)" flake — a test
# asserting `Open3.expects(:capture3).never` failing because whichever test drew
# the slot before it in that worker left the catalog cache cold. See
# test/support/air_catalog_cache_warmer.rb for the full rationale.
class AirCatalogCacheWarmerTest < ActiveSupport::TestCase
  test "a snapshot of the boot-resolved catalog was captured" do
    assert AirCatalogCacheWarmer.captured?,
      "the boot pre-warm must produce a snapshot, otherwise restore! is a no-op " \
      "and every test is back to inheriting its predecessor's cache"
  end

  # The base-class setup in test_helper runs before this test body, so the cache
  # is already warm here — which is the whole guarantee. Reading the catalog must
  # therefore touch no subprocess, with nothing in this test having arranged it.
  test "every test starts with a warm catalog, so reading it shells out to nothing" do
    Open3.expects(:capture3).never

    assert AirCatalogService.entries_for(:roots).any?,
      "expected the restored snapshot to carry the resolved agent roots"
    assert AirCatalogService.entries_for(:skills).any?,
      "expected the restored snapshot to carry the resolved skills"
  end

  # If restore! were vacuous, entries_for would fall through to a real
  # `air resolve` here and this test would fail the same way the flake did.
  test "restore! re-warms a cache a previous test cleared" do
    AirCatalogService.reset!

    AirCatalogCacheWarmer.restore!

    Open3.expects(:capture3).never
    assert AirCatalogService.entries_for(:roots).any?
    assert_not AirCatalogService.degraded?,
      "a restored snapshot is real resolve output, not a degraded fallback"
    assert_nil AirCatalogService.resolve_failure
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

    Open3.expects(:capture3).never

    session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/1" ] })
  end
end
