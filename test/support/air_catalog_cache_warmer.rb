# frozen_string_literal: true

# Keeps every test's AIR catalog cache warm, so no test inherits the previous
# test's catalog state.
#
# Why this exists
# ---------------
# AirCatalogService caches its resolved artifact tree in process-global ivars on
# the class. test_helper resolves that tree once at boot, before parallelize()
# forks its workers, and the whole suite leans on the result: with a warm cache
# `AirCatalogService.entries_for` returns memoized data, and with a cold one it
# shells out to `Open3.capture3(air, "resolve", ...)` — a real subprocess, in the
# middle of an unrelated test.
#
# The reach of that is much wider than the tests that name the service. Any
# committed write to a session attribute the sessions index displays broadcasts
# the session card, and sessions/_session_card.html.erb renders
# Session#agent_root_key -> AgentRootsConfig.find_for_session ->
# AirCatalogService.entries_for(:roots). So an ordinary
# `session.update!(custom_metadata: ...)` resolves the catalog whenever the cache
# happens to be cold.
#
# Tests that exercise the service itself must control that cache, and
# AirCatalogServiceTest's teardown calls AirCatalogService.reset! to hand it back
# empty. Whatever runs next in the same worker then pays for the resolve. That is
# how GithubCommentPollerJobTest#test_poll_comments_for_session_ignores_a_merge_
# gate_review_comment failed on main at --seed 40537: it asserts
# `Open3.expects(:capture3).never`, the assertion only holds while the cache is
# warm, and nothing in the test made it warm — it was inheriting warmth from
# whichever test drew the slot before it. A different seed, a different victim.
#
# The two failure shapes a leaked cache produces:
#   - cold  -> an unrelated test shells out (breaks `.never` expectations, and
#              spends a real subprocess per occurrence)
#   - fake  -> a tree left behind by a stubbed resolve, so an unrelated Session
#              validation rejects a catalog_skills / agent_root that does exist
#
# This module snapshots the boot-resolved tree and re-installs it before every
# test (see the global setup in test_helper). Each test therefore starts from the
# same real, warm catalog no matter what its predecessor did, and the `.never`
# expectations are guaranteed by construction rather than by seed luck.
module AirCatalogCacheWarmer
  class << self
    # Snapshot the boot-resolved tree. Called once from test_helper, after the
    # pre-warm and before parallelize() forks, so every worker inherits it.
    #
    # A snapshot is only taken when the pre-warm actually produced entries: if
    # catalog resolution is broken, capturing the empty tree would pin every test
    # to an empty catalog and turn one broken resolve into a suite-wide failure
    # with no diagnostic. Leaving @snapshot nil makes restore! a no-op, and the
    # service falls back to its own resolve/last-known-good handling.
    def capture!
      tree = AirCatalogService::ARTIFACT_TYPES.index_with { |type| AirCatalogService.entries_for(type) }
      @snapshot = tree if tree.values.any?(&:present?)
    rescue AirCatalogService::CatalogError => e
      warn "[AirCatalogCacheWarmer] could not snapshot the catalog: #{e.message}"
      @snapshot = nil
    end

    # True when a snapshot was captured at boot and restore! has something to do.
    def captured?
      !@snapshot.nil?
    end

    # Re-install the boot snapshot as AirCatalogService's in-memory cache.
    # Cheap enough to run before every test — a handful of ivar writes, no I/O.
    #
    # The snapshot object is installed as-is rather than deep-duped: nothing in
    # the app mutates the tree in place (load! and serve_last_known_good! both
    # replace it wholesale), and duping it ~10k times would cost more than the
    # flake.
    def restore!
      AirCatalogService.seed_cache!(@snapshot) if @snapshot
    end
  end
end
