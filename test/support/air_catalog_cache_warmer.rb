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
# how the comment poller's `ignores a merge gate review comment` case (then
# GithubCommentPollerJobTest, now Github::CommentEvaluatorTest) failed on main at
# --seed 40537: it asserts
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
  # The artifact types the suite's session-creation coupling actually depends on:
  # Session validates agent_root against :roots and catalog_skills against
  # :skills. A snapshot missing either would pin every test to a catalog that
  # fails those validations — see capture!.
  REQUIRED_TYPES = %i[roots skills].freeze

  class << self
    # Snapshot the boot-resolved tree. Called once from test_helper, after the
    # pre-warm and before parallelize() forks, so every worker inherits it.
    #
    # The guard demands the types the suite cannot run without, rather than
    # merely "something resolved". A partial tree — a half-fetched source, an
    # air.json that drops roots.json, a CatalogSnapshot fallback carrying fewer
    # types — would otherwise be pinned to every test and produce exactly the
    # suite-wide ActiveRecord::RecordInvalid wave described in CLAUDE.md's "Known
    # coupling", except now immune to reset!. Leaving @snapshot nil instead makes
    # restore! a no-op and hands catalog resolution back to the service's own
    # fallback handling, which is what the suite did before this module existed.
    def capture!
      tree = AirCatalogService::ARTIFACT_TYPES.index_with { |type| AirCatalogService.entries_for(type) }
      return unless REQUIRED_TYPES.all? { |type| tree[type].present? }

      @snapshot = deep_freeze(tree)
    rescue AirCatalogService::CatalogError => e
      warn "[AirCatalogCacheWarmer] could not snapshot the catalog: #{e.message}"
    end

    # True when a snapshot was captured at boot and restore! has something to do.
    def captured?
      !@snapshot.nil?
    end

    # Re-install the boot snapshot as AirCatalogService's in-memory cache.
    # Cheap enough to run before every test — a handful of ivar writes, no I/O.
    def restore!
      AirCatalogService.seed_cache!(@snapshot) if @snapshot
    end

    private

    # Freeze the tree rather than deep-duping it per test: duping ~10k times
    # would cost more than the flake, but handing out one shared mutable object
    # is worse than what it replaces. Before this module, an in-place mutation of
    # the catalog tree healed itself at the next resolve; now the snapshot IS the
    # object every test gets, so one mutation would poison the rest of the worker
    # and reset! could not clear it. Freezing turns that silent poisoning into a
    # FrozenError at the mutation site. Nothing in the app mutates the tree —
    # DeploymentInfoService, the one component that transforms catalog data,
    # deep_dups first — so this should never fire.
    def deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }.freeze
      when Array then value.each { |v| deep_freeze(v) }.freeze
      else value.freeze
      end
    end
  end
end
