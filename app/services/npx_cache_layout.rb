# frozen_string_literal: true

# Where a session's npm caches live inside its clone — the single owner of that
# layout, for every mechanism that writes it, walks it, or cleans it up.
#
# The layout has two shapes, and both matter:
#
#   <clone>/.npm-cache/_npx/<hash>/…                      the shared root
#   <clone>/.npm-cache/isolated/<server>/_npx/<hash>/…     a per-server root
#
# The isolated form exists because npx keys its install directory purely on the
# package spec, so two MCP servers running the byte-identical
# `npx -y <pkg>@latest` race into one tree. NpxCacheIsolator gives each of them a
# root of its own; NpxCacheHealService deletes a corrupted tree in either shape;
# NpxBinExecutableGuard walks both for bin shims that need their execute bit back.
#
# This module exists because those three were written separately and did not all
# know about both shapes. The isolator added the isolated root and taught the heal
# service about it, and the guard — landing the same week — kept globbing only the
# shared one, which silently opted every isolated server out of the EACCES repair
# it most needed (zimmer#498). One place that both *constructs* and *discovers*
# cache roots is what keeps the next mechanism from repeating that: a new shape
# added here is a shape every consumer sees.
module NpxCacheLayout
  # The clone-local npm cache. Everything below lives inside it, which is what
  # keeps CacheClearService's `**/.npm-cache` sweep able to reclaim all of it.
  CACHE_DIRNAME = ".npm-cache"

  # The parent of the per-server roots, inside the shared cache.
  ISOLATED_SUBDIR = "isolated"

  # npm's own name for the install root inside a cache.
  NPX_DIRNAME = "_npx"

  module_function

  # The npm cache the whole clone shares, and the parent of every isolated root.
  #
  # @param working_directory [String] the session's clone working directory
  # @return [String] absolute path
  def shared_cache_dir(working_directory)
    File.join(working_directory, CACHE_DIRNAME)
  end

  # The npm cache one isolated server keeps to itself.
  #
  # Named after the server rather than the package, so two servers running the
  # same package land in different trees — which is the entire point. The name is
  # sanitized for the filesystem; two names that sanitize to the same string would
  # simply share a cache again, i.e. degrade to the un-isolated behavior rather
  # than to something worse.
  #
  # @param working_directory [String] the session's clone working directory
  # @param server_name [String]
  # @return [String] absolute path
  def isolated_cache_dir(working_directory, server_name)
    File.join(shared_cache_dir(working_directory), ISOLATED_SUBDIR, sanitize_server_name(server_name))
  end

  # A filesystem-safe directory name for a server. `.` and `..` are rejected
  # rather than sanitized: both resolve back to a shared parent, which would put
  # the server on the very cache isolation exists to keep it off. Every other
  # name collapses to a plain segment inside the clone.
  def sanitize_server_name(server_name)
    sanitized = server_name.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
    return "unnamed" if sanitized.blank? || sanitized.delete(".").empty?

    sanitized
  end

  # Every `_npx` root in the clone: the shared one directly under `.npm-cache`,
  # and each per-server root beneath it. Restricted to one level of nesting so
  # the glob stays bounded on a large cache.
  #
  # The nested pattern is `<cache>/*/*/_npx` rather than
  # `<cache>/#{ISOLATED_SUBDIR}/*/_npx` deliberately: discovery is one notch wider
  # than construction, so a root left by an earlier layout — or by a mechanism
  # that lands beside this one — is still found rather than silently skipped.
  # Nothing is *acted on* because it was discovered; callers containment-check
  # each root with #within_clone_cache? before touching it.
  #
  # The shared root is returned whether or not it exists (callers either skip a
  # missing directory or are asking for a path to remove); the nested roots come
  # from a glob, so those necessarily do.
  #
  # @param working_directory [String, nil] the session's clone working directory
  # @param hash [String, nil] when given, the specific `_npx/<hash>` tree
  # @return [Array<String>]
  def npx_dirs(working_directory, hash = nil)
    return [] if working_directory.blank?

    leaf = hash ? File.join(NPX_DIRNAME, hash) : NPX_DIRNAME
    cache_root = shared_cache_dir(working_directory)

    [ File.join(cache_root, leaf), File.join(cache_root, "*", "*", leaf) ]
      .flat_map { |pattern| pattern.include?("*") ? Dir.glob(pattern) : [ pattern ] }
      .uniq
  end

  # Whether a path is inside some Zimmer clone's npm cache, and therefore
  # something Zimmer may delete from or chmod. Only paths that live under
  # ~/.zimmer/clones AND carry both a `.npm-cache` and an `_npx` segment qualify.
  #
  # The two segments are checked independently rather than as one adjacent
  # `.npm-cache/_npx` string: an isolated server keeps its cache at
  # `.npm-cache/isolated/<server>/_npx/<hash>`, which is just as much this clone's
  # npm cache and just as safe to touch.
  #
  # Callers apply this per root, so one root that escapes the clones directory is
  # skipped on its own rather than disqualifying the others.
  def within_clone_cache?(path)
    return false if path.blank?

    expanded = File.expand_path(path)
    # Reuse CacheClearService's clones-base definition so the security-relevant
    # path has a single source of truth (it's a lambda so it honors Dir.home at
    # call time, which lets tests redirect HOME).
    clones_base = File.expand_path(CacheClearService::CLONES_BASE_DIR.call)
    separator = File::SEPARATOR

    expanded.start_with?(clones_base + separator) &&
      expanded.include?("#{separator}#{CACHE_DIRNAME}#{separator}") &&
      (expanded.include?("#{separator}#{NPX_DIRNAME}#{separator}") ||
        expanded.end_with?("#{separator}#{NPX_DIRNAME}"))
  end
end
