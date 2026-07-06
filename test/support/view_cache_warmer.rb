# frozen_string_literal: true

# Eagerly resolves every application view template into the ActionView resolver
# cache at test boot, BEFORE parallelize() forks workers.
#
# Why this exists
# ---------------
# With template-load caching enabled (reloading is disabled in test, and the
# unit shards additionally set eager_load via ENV["CI"]),
# ActionView::FileSystemResolver memoizes the result of each template lookup in
# a persistent Concurrent::Map keyed by virtual path. The lookup runs a
# Dir.glob and caches whatever it finds — INCLUDING an empty result.
#
# That makes a transient miss catastrophic: if a single Dir.glob momentarily
# returns nothing (a filesystem/dirent visibility hiccup, which happens on the
# persistent self-hosted CI runner under a sharded parallel run), the empty
# array is memoized for that virtual path and every subsequent render of that
# partial in that worker process raises ActionView::MissingTemplate — for a file
# that is sitting right there on disk. This is exactly how three notifications
# controller actions that all render notifications/_notification_badge failed
# identically in one worker while the partial demonstrably existed.
#
# The fix is to populate POSITIVE cache entries once, single-threaded, while the
# filesystem is quiescent (at boot, before fixtures load and before workers
# fork). Forked workers inherit the warm cache copy-on-write, so they never
# perform a cold — and therefore raceable — glob for an application template.
module ViewCacheWarmer
  module_function

  # Resolves every template reachable from +view_paths+ so each one lands in the
  # resolver's persistent cache as a hit. Returns the sorted, de-duplicated list
  # of virtual paths that were warmed.
  #
  # Going through LookupContext#find_all (rather than Resolver#find_all directly)
  # is deliberate: only the keyed lookup path writes to the persistent
  # @unbound_templates cache. The format/locale details do not matter here —
  # the resolver globs and caches every variant of a virtual path regardless of
  # the requested details, so a single call per virtual path warms it fully.
  def warm!(view_paths = ActionController::Base.view_paths)
    lookup_context = ActionView::LookupContext.new(view_paths)
    warmed = []

    view_paths.each do |resolver|
      next unless resolver.respond_to?(:all_template_paths)

      resolver.all_template_paths.each do |template_path|
        lookup_context.find_all(
          template_path.name,
          Array(template_path.prefix),
          template_path.partial
        )
        warmed << template_path.virtual
      end
    end

    warmed.uniq.sort
  end
end
