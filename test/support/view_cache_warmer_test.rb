# frozen_string_literal: true

require "test_helper"

# Guards the boot-time view-cache warm-up that prevents the
# ActionView::MissingTemplate-on-an-existing-partial flake (notifications
# controller actions rendering notifications/_notification_badge). See
# test/support/view_cache_warmer.rb for the full rationale.
class ViewCacheWarmerTest < ActiveSupport::TestCase
  test "warms the notification badge partial that previously flaked" do
    warmed = ViewCacheWarmer.warm!

    assert_includes warmed, "notifications/_notification_badge",
      "warm-up must touch the previously-flaky partial so its lookup is cached as a hit"
  end

  test "warms a broad set of application templates" do
    warmed = ViewCacheWarmer.warm!

    assert_operator warmed.size, :>, 20,
      "expected the warm-up to resolve the full application view tree, got #{warmed.size}"
    # Sanity-check it found both a partial and a full template.
    assert(warmed.any? { |v| v.include?("/_") }, "expected at least one partial to be warmed")
  end

  # This is the test that actually proves the mechanism: it reproduces the
  # production flake (a transient Dir.glob miss memoized as a permanent negative
  # cache entry) and shows that warming immunizes against it.
  #
  # Two independent PathSets over the same view directory are used so the test
  # mutates no global resolver state and is safe under parallelization:
  #   - warmed_paths is pre-warmed (positive entry cached for the partial)
  #   - cold_paths is left cold (control)
  # Then Dir.glob is stubbed to return [] for BOTH, simulating the transient
  # filesystem hiccup. The warmed lookup must still resolve (it hits the cache
  # without re-globbing); the cold lookup must come back empty (it globs live,
  # gets nothing, and memoizes the negative result) — which is precisely the
  # MissingTemplate failure mode. If warming were a no-op, the warmed assertion
  # would fail, so this test genuinely guards the cache-write.
  test "warming immunizes a partial against a later transient Dir.glob miss" do
    views = Rails.root.join("app/views").to_s

    warmed_paths = ActionView::PathSet.new([ ActionView::FileSystemResolver.new(views) ])
    ViewCacheWarmer.warm!(warmed_paths)
    warmed_context = ActionView::LookupContext.new(warmed_paths)
    warmed_context.formats = [ :html ]

    cold_paths = ActionView::PathSet.new([ ActionView::FileSystemResolver.new(views) ])
    cold_context = ActionView::LookupContext.new(cold_paths)
    cold_context.formats = [ :html ]

    warmed_result = nil
    cold_result = nil

    # Simulate the transient filesystem miss that poisons the resolver cache.
    Dir.stub :glob, [] do
      warmed_result = warmed_context.find_all("notification_badge", [ "notifications" ], true)
      cold_result = cold_context.find_all("notification_badge", [ "notifications" ], true)
    end

    refute_empty warmed_result,
      "warmed partial must still resolve from cache despite a later transient glob miss"
    assert_empty cold_result,
      "control: an un-warmed lookup during the glob miss memoizes an empty (negative) result"
  end
end
