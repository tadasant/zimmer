# frozen_string_literal: true

# Single discovery surface for AIR catalog content.
#
# Thin shim over the AIR CLI's `air resolve --json` command. AIR owns all catalog
# resolution logic (local paths, github:// URIs, `catalogs` composition, provider
# caching). This service shells out to the installed CLI, parses the merged
# artifact tree, and exposes it to the rest of the app.
#
# Two layers of caching:
#   - 60 second in-memory TTL on the parsed artifact tree
#   - refresh!: runs `air update` to refresh provider caches (github clones),
#     then reloads the in-memory tree. Used by CatalogRefreshJob (every 15 min)
#     and the manual /catalogs/refresh endpoint.
class AirCatalogService
  class CatalogError < StandardError; end

  CATALOG_CACHE_TTL = 60 # seconds
  GITHUB_CACHE_DIR = File.expand_path("~/.air/cache/github")
  ARTIFACT_TYPES = %i[skills mcp roots references hooks plugins].freeze

  # AIR drops a declared reference (and prints "... Dropping the reference." on
  # stderr while still exiting 0) for two distinct reasons:
  #
  #   1. The target does not exist in the resolved pool — the warning reads
  #      "... references unknown <type> \"<id>\". ... Dropping the reference."
  #      This is the structurally-incomplete case: a stale, partially-fetched, or
  #      missing catalog source silently strips affected roots' defaults.
  #   2. The target exists but is intentionally removed by air.json#exclude — the
  #      warning reads "... which is removed by air.json#exclude (...). Dropping
  #      the reference." This is an expected, author-intended configuration.
  #
  # Only case 1 indicates a degraded resolve, so the unknown-reference marker
  # (not the bare drop marker, which both cases share) is the discriminator.
  # Matching on AIR's exact stderr wording — string copy, not a stable contract —
  # is brittle, but AIR exposes no machine-readable signal for dropped references.
  # See run_air_resolve!.
  UNKNOWN_REFERENCE_MARKER = "references unknown"
  DROPPED_REFERENCE_MARKER = "Dropping the reference"

  class << self
    # Get all entries for an artifact type, keyed by ID.
    # @param type [Symbol] one of ARTIFACT_TYPES
    # @return [Hash{String => Hash}] entry hash from air resolve output
    def entries_for(type)
      ensure_loaded
      @entries[type] || {}
    end

    # Path to the base air.json file (set via Rails config). This is the
    # unpinned source; catalog pins are layered on top by effective_air_json_path.
    def air_json_path
      Rails.application.config.air_json_path
    end

    # Path to the air.json the AIR CLI should actually use. When CatalogPins
    # exist, the base config is rewritten to freeze each pinned catalog to its
    # ref (see AirCatalogRefRewriter) and written to a process-unique
    # tmp/air.effective.<pid>.json (see effective_config_path); otherwise the
    # base path is returned as-is.
    #
    # Memoized on CatalogPin.fingerprint so every process (web + worker)
    # regenerates its local copy the moment the pin set changes in the shared
    # DB — no inter-process signal needed. Falls back to the base config if pin
    # application fails, so a bad pin never takes down all catalog resolution.
    def effective_air_json_path
      base = air_json_path
      fingerprint = CatalogPin.fingerprint
      if @effective_path && @effective_fingerprint == fingerprint && File.exist?(@effective_path)
        return @effective_path
      end

      pins = CatalogPin.as_map
      @effective_fingerprint = fingerprint
      @effective_path = pins.empty? ? base : generate_effective_config(base, pins)
    rescue => e
      Rails.logger.error "[AirCatalogService] Failed to apply catalog pins: #{e.class}: #{e.message}"
      air_json_path
    end

    # The github:// catalog prefixes declared in the base air.json, normalized
    # to `github://owner/repo` (path and any ref stripped). These are the
    # catalogs the settings UI offers to pin.
    # @return [Array<String>]
    def pinnable_catalogs
      return [] unless File.exist?(air_json_path)

      parsed = JSON.parse(File.read(air_json_path))
      Array(parsed["catalogs"]).filter_map { |uri| github_prefix(uri) }.uniq
    rescue JSON::ParserError, SystemCallError => e
      Rails.logger.warn "[AirCatalogService] Could not read pinnable catalogs: #{e.message}"
      []
    end

    # Resolve the commit SHA a catalog currently points at, by reading the AIR
    # provider cache clone. Used by the settings UI to show what is live and to
    # capture a SHA for "pin to current HEAD".
    # @param catalog_uri [String] e.g. "github://tadasant/zimmer-catalog"
    # @param ref [String] cache subdir to read ("HEAD" for the default branch)
    # @return [String, nil] full commit SHA, or nil if not cached
    def resolved_sha_for(catalog_uri, ref: "HEAD")
      owner_repo = github_owner_repo(catalog_uri)
      return nil unless owner_repo

      owner, repo = owner_repo
      clone_dir = File.join(GITHUB_CACHE_DIR, owner, repo, ref)
      return nil unless File.directory?(File.join(clone_dir, ".git"))

      stdout, _stderr, status = Open3.capture3("git", "-C", clone_dir, "rev-parse", "HEAD")
      status.success? ? stdout.strip.presence : nil
    end

    # The directory containing air.json — preserved for callers that still
    # reference it (e.g. AirPrepareService uses air_json_path to set AIR_CONFIG).
    def air_json_dir
      File.dirname(air_json_path)
    end

    # Re-invoke `air resolve --json` and refresh the in-memory entry tree from
    # its output. Does NOT fetch upstream provider data — use refresh! for that.
    # Deliberately does not clear @entries first: if the fresh resolve fails,
    # load! falls back to the existing in-memory tree (see serve_last_known_good!)
    # rather than dropping the whole catalog to empty.
    def reload!
      @loaded_at = nil
      load!
    end

    # True when the most recent resolve failed and the service is serving a
    # last-known-good catalog (in-memory or persisted) instead of fresh data.
    # Surfaces the degraded state to health checks / the settings UI.
    def degraded?
      @degraded == true
    end

    # Wall-clock time of the catalog tree currently being served — the last
    # successful resolve, or the persisted snapshot's resolved_at when degraded.
    # nil before the first load.
    def last_known_good_at
      @last_known_good_at
    end

    # Pull latest provider caches (github clones) via `air update`, then reload
    # the in-memory entry tree. This is the "pull latest catalog" operation
    # invoked by CatalogRefreshJob and the manual refresh endpoint.
    def refresh!
      raise CatalogError, "air.json not found at #{air_json_path}" unless File.exist?(air_json_path)

      run_air_update!
      reload!
      true
    end

    # Wall-clock time of the last provider-cache refresh. Derived from FETCH_HEAD
    # mtimes on cached github clones so the value survives process restarts —
    # important for the "Updated X ago" indicator that would otherwise reset on
    # every deploy. Returns nil if no github clones exist yet.
    def last_refreshed_at
      return nil unless File.directory?(GITHUB_CACHE_DIR)

      Dir.glob(File.join(GITHUB_CACHE_DIR, "**", ".git", "FETCH_HEAD"))
        .filter_map { |p| File.mtime(p) if File.exist?(p) }
        .max
    end

    # Find the local clone path for a given github repo URL.
    # Used by WarmSkillsCacheJob to locate cached clones for repo-native skill
    # discovery. Scans the AIR github cache directory (~/.air/cache/github/
    # <owner>/<repo>/<ref>) for a matching repo.
    # @param url [String] e.g. "https://github.com/tadasant/zimmer-catalog.git"
    # @return [String, nil] absolute path to the clone root, or nil if not found
    def repo_root_for(url:)
      return nil if url.blank?
      return nil unless File.directory?(GITHUB_CACHE_DIR)

      normalized = normalize_repo_url(url)
      owner_repo = extract_owner_repo(normalized)
      return nil unless owner_repo

      owner, repo = owner_repo
      repo_dir = File.join(GITHUB_CACHE_DIR, owner, repo)
      return nil unless File.directory?(repo_dir)

      # Prefer HEAD (default ref) when present, otherwise any clone.
      preferred = File.join(repo_dir, "HEAD")
      return preferred if File.directory?(File.join(preferred, ".git"))

      Dir.glob(File.join(repo_dir, "*")).find { |d| File.directory?(File.join(d, ".git")) }
    end

    # Test/dev hook: clear all caches.
    def reset!
      @loaded_at = nil
      @entries = nil
      @effective_path = nil
      @effective_fingerprint = nil
      @degraded = nil
      @last_known_good_at = nil
    end

    private

    def ensure_loaded
      load! if @entries.nil? || expired?
    end

    def expired?
      @loaded_at &&
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @loaded_at) > CATALOG_CACHE_TTL
    end

    # Resolve the catalog tree and cache it in memory. On success, persist a
    # last-known-good snapshot. On any CatalogError (collision hard-fail, network
    # failure, broken install, missing air.json), fall back to the last-known-good
    # tree — in-memory first, then the persisted snapshot — so a broken upstream
    # catalog cannot take session creation (and the zimmer-router lookup behind every
    # routable message) down to an empty catalog. Only re-raises when there is no
    # fallback at all (first-ever boot with a broken catalog).
    def load!
      raise CatalogError, "air.json not found at #{air_json_path}" unless File.exist?(air_json_path)

      parsed = parse_resolve_output(run_air_resolve!)
      store_loaded_entries(normalize_parsed(parsed))
    rescue CatalogError => e
      serve_last_known_good!(e)
    end

    # Cache a freshly resolved tree, persist it as the new last-known-good
    # snapshot, and clear any degraded state.
    def store_loaded_entries(entries)
      Rails.logger.info "[AirCatalogService] catalog resolution recovered; serving freshly resolved catalog" if @degraded
      @entries = entries
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @last_known_good_at = Time.current
      @degraded = false
      persist_snapshot(entries)
    end

    # Serve the last-known-good catalog after a failed resolve. Prefers the
    # in-memory tree (a prior success in this process), then the persisted
    # snapshot (survives restarts, shared across web + worker). Re-raises only
    # when neither exists. Refreshes @loaded_at so we serve the stale tree for a
    # full TTL before retrying, rather than re-shelling out on every request.
    def serve_last_known_good!(error)
      source, entries, resolved_at =
        if @entries.present?
          [ :memory, @entries, @last_known_good_at ]
        elsif (snapshot = CatalogSnapshot.latest)
          [ :snapshot, entries_from_snapshot(snapshot.entries), snapshot.resolved_at ]
        end

      unless entries
        Rails.logger.error "[AirCatalogService] air resolve failed (#{error.message}) and no last-known-good " \
          "snapshot exists; catalog is unavailable and session creation will fail until resolution succeeds."
        raise error
      end

      log_degraded(error, source, resolved_at)
      @entries = entries
      @last_known_good_at = resolved_at
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @degraded = true
    end

    # Log the degraded fallback. Alerts (.error) only on the transition from
    # healthy to degraded; subsequent per-TTL fallbacks log at .info to avoid
    # alert spam while the upstream catalog stays broken. The transition alert
    # is preserved (not downgraded) so a persistently broken catalog keeps
    # surfacing on the next deploy / cold boot.
    def log_degraded(error, source, resolved_at)
      stamp = resolved_at ? " from #{resolved_at.iso8601}" : ""
      message = "[AirCatalogService] air resolve failed (#{error.message}); serving last-known-good catalog" \
        "#{stamp} (source: #{source}). Session creation continues on the stale catalog; resolution must be repaired."
      if @degraded
        Rails.logger.info message
      else
        Rails.logger.error message
      end
    end

    # Persist the resolved tree as the last-known-good snapshot. A snapshot-write
    # failure must never break catalog resolution, so DB errors are swallowed
    # (logged at .warn) rather than propagated.
    def persist_snapshot(entries)
      CatalogSnapshot.store!(entries)
    rescue => e
      Rails.logger.warn "[AirCatalogService] failed to persist catalog snapshot: #{e.class}: #{e.message}"
    end

    # Shape a raw `air resolve` parse into the type-keyed tree, dropping any
    # non-hash entries defensively.
    def normalize_parsed(parsed)
      ARTIFACT_TYPES.index_with do |type|
        entries = parsed[type.to_s]
        entries.is_a?(Hash) ? entries.select { |_id, entry| entry.is_a?(Hash) } : {}
      end
    end

    # Shape a persisted snapshot (jsonb, string-keyed at the top level) back into
    # the type-keyed tree the service serves.
    def entries_from_snapshot(raw)
      ARTIFACT_TYPES.index_with do |type|
        entries = raw[type.to_s]
        entries.is_a?(Hash) ? entries : {}
      end
    end

    def parse_resolve_output(stdout)
      JSON.parse(stdout)
    rescue JSON::ParserError => e
      raise CatalogError, "Invalid JSON from air resolve: #{e.message}"
    end

    # Invoke `air resolve --json --no-scope --git-protocol https` with AIR_CONFIG
    # pointing at the configured air.json. Returns stdout.
    #
    # `--no-scope` (AIR 0.1.1+) emits shortname-keyed output and rewrites
    # qualified references inside entries back to bare IDs. Zimmer surfaces bare
    # shortnames everywhere (UI, DB, Session.catalog_skills, agent root
    # defaults), so this matches our internal model directly. AIR hard-fails
    # the resolve if any cross-scope shortname collision exists; the resulting
    # error surfaces as CatalogError below, which is the right outcome — the
    # operator must drop one side via `air.json#exclude`.
    def run_air_resolve!
      ensure_air_cli!

      stdout, stderr, status = Open3.capture3(air_env, air_binary, "resolve", "--json", "--no-scope", "--git-protocol", "https")
      unless status.success?
        raise CatalogError, "air resolve failed (exit #{status.exitstatus}): #{stderr.presence || stdout}"
      end

      # A resolve can exit 0 yet be structurally incomplete. When a catalog
      # source is stale, partially fetched, or missing, AIR cannot resolve every
      # declared reference, so it drops the unresolvable ones and emits
      # "references unknown ... Dropping the reference" warnings on stderr while
      # still exiting 0. The dropped references are exactly what strips affected
      # roots' default_skills / default_mcp_servers / default_hooks — including
      # the zimmer-router defaults behind every chat_bubble / quick_prompt session.
      # Persisting such a tree would misconfigure every session created against it
      # (empty MCP / Skills / Hooks) AND overwrite the last-known-good snapshot
      # with the degraded data. A healthy resolve emits no unknown-reference
      # warnings, so treat them as a failed resolve: raising here routes load!
      # into serve_last_known_good! and never reaches persist_snapshot.
      dropped = unknown_reference_warnings(stderr)
      if dropped.any?
        raise CatalogError, "air resolve exited 0 but dropped #{dropped.size} unresolvable reference(s), " \
          "indicating an incomplete catalog resolve (first: #{dropped.first.inspect})"
      end

      stdout
    end

    # Lines on `air resolve` stderr signalling a declared reference was dropped
    # because its target does not exist in the resolved pool (the structurally-
    # incomplete case). References dropped by air.json#exclude share the
    # DROPPED_REFERENCE_MARKER but are intentional, so they are excluded here by
    # requiring the UNKNOWN_REFERENCE_MARKER as well.
    def unknown_reference_warnings(stderr)
      return [] if stderr.blank?

      stderr.each_line.filter_map do |line|
        stripped = line.strip
        stripped if stripped.include?(UNKNOWN_REFERENCE_MARKER) && stripped.include?(DROPPED_REFERENCE_MARKER)
      end
    end

    # Invoke `air update --git-protocol https` to refresh provider caches.
    def run_air_update!
      ensure_air_cli!

      stdout, stderr, status = Open3.capture3(air_env, air_binary, "update", "--git-protocol", "https")
      unless status.success?
        raise CatalogError, "air update failed (exit #{status.exitstatus}): #{stderr.presence || stdout}"
      end
      Rails.logger.info "[AirCatalogService] air update: #{stdout.strip}" if stdout.present?
    end

    # Lazy-install AIR CLI on first use. Converts AirPrepareError to CatalogError
    # so callers that rescue CatalogError get a consistent failure mode.
    def ensure_air_cli!
      AirPrepareService.ensure_air_installed!
    rescue AirPrepareService::AirPrepareError => e
      raise CatalogError, "AIR CLI installation failed: #{e.message}"
    end

    def air_binary
      File.join(AirPrepareService::AIR_INSTALL_DIR, "node_modules", ".bin", "air")
    end

    def air_env
      { "AIR_CONFIG" => effective_air_json_path }
    end

    # Rewrite the base air.json with the pin set and persist it to tmp/. Returns
    # the path to the generated file.
    def generate_effective_config(base_path, pins)
      raise CatalogError, "air.json not found at #{base_path}" unless File.exist?(base_path)

      rewritten = AirCatalogRefRewriter.rewrite(File.read(base_path), pins: pins)
      out_path = effective_config_path
      FileUtils.mkdir_p(out_path.dirname)
      File.write(out_path, rewritten)
      out_path.to_s
    end

    # On-disk location for the rewritten pin config. The filename MUST stay
    # process-unique (keyed on Process.pid): every process that resolves the
    # catalog — each web Puma worker, each GoodJob worker, and each parallel
    # test worker — shares the same filesystem, so a single fixed path lets two
    # processes writing different pin sets clobber each other's file. A reader
    # could then feed a config it didn't write to `air resolve`. Memoization is
    # per-process (@effective_path), so a per-process file is the natural match
    # and keeps production behavior identical (each process maintains its own
    # local copy, regenerated when the DB fingerprint changes).
    #
    # This is the same class of shared-tmp-file race that issue #3455/#3741 hit
    # for FileStorageService; keep the path process-unique. See issue #4113.
    #
    # No cleanup job reaps these files: a process overwrites its own file on
    # every fingerprint change, so a single process never accumulates more than
    # one. Across deploys/restarts the bound is the ephemeral tmp/ itself —
    # production tmp/ lives on the container overlay and is wiped on every
    # container recreation (see CLAUDE.md "Ephemeral vs Durable Storage"), and
    # test tmp/ is short-lived — so stale-pid files can't grow without bound.
    def effective_config_path
      Rails.root.join("tmp", "air.effective.#{Process.pid}.json")
    end

    # Extract [owner, repo] from a github:// catalog URI, stopping at the first
    # path/ref delimiter. Returns nil for non-github URIs.
    def github_owner_repo(catalog_uri)
      m = catalog_uri.to_s.match(%r{\Agithub://([^/@\s]+)/([^/@\s]+)})
      m ? [ m[1], m[2] ] : nil
    end

    # Normalize a github:// URI to its `github://owner/repo` prefix.
    def github_prefix(uri)
      owner_repo = github_owner_repo(uri)
      owner_repo ? "github://#{owner_repo[0]}/#{owner_repo[1]}" : nil
    end

    def normalize_repo_url(url)
      url.to_s.sub(%r{/+\z}, "").sub(/\.git\z/, "").downcase
    end

    # Extract [owner, repo] from a normalized github URL (https or git@).
    def extract_owner_repo(normalized_url)
      case normalized_url
      when %r{github\.com[/:]([^/]+)/([^/]+)\z}
        [ $1, $2 ]
      end
    end
  end
end
