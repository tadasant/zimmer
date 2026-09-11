# frozen_string_literal: true

# Single discovery surface for AIR catalog content.
#
# Thin shim over the AIR CLI's `air resolve --json` command. AIR owns all catalog
# resolution logic (local paths, github:// URIs, `catalogs` composition, provider
# caching). This service shells out to the installed CLI, parses the merged
# artifact tree, and exposes it to the rest of the app.
#
# The persisted CatalogSnapshot is the source of truth for the resolved tree,
# in every process. In production the web (Puma) and worker (GoodJob) run in
# separate containers with separate ~/.air/cache directories, and only a
# process that has just fetched its provider clones can resolve a fresh tree —
# so resolving is a write, and serving is a read:
#
#   - Resolve (write): refresh! runs `air update` then `air resolve` and stores
#     the result as the new snapshot. It runs once at boot in every process, on
#     the worker's */15 CatalogRefreshJob cron, behind the "Refresh catalogs"
#     button (which enqueues that same job), and when a catalog pin is saved.
#     reload! resolves without fetching, and a process with no snapshot to
#     serve resolves on first use.
#   - Serve (read): a 60 second in-memory TTL on the parsed tree. When it
#     expires the process reads the newest snapshot's header — one narrow
#     query — and loads the tree only when that row is newer than the one it
#     is serving. No process re-resolves on a timer, and none needs its own
#     disk to be fresh to serve the catalog the fleet last resolved.
#
# Catalog health travels the same way: a failed refresh is recorded on the
# newest snapshot, so a process that never resolves still reports degraded?
# and resolve_failure truthfully.
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

    # Path to the air.json the AIR CLI should actually use. When a CatalogPin
    # actually pins one of the catalogs the base config declares, that config is
    # rewritten to freeze the pinned catalog to its ref (see
    # AirCatalogRefRewriter) and written to a process-unique
    # tmp/air.effective.<pid>.json (see effective_config_path); otherwise — no
    # pins at all, or pins that match nothing in this config — the base path is
    # returned as-is.
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

    # The commit SHA a catalog resolved to in the snapshot this process serves.
    # Used by the settings UI to show what is live and to capture a SHA for
    # "pin to current HEAD".
    #
    # Read from the snapshot, not from this process's provider cache: the SHA
    # that matters is the one the served tree was resolved from, and the writer
    # recorded it off its own disk at resolve time (see local_catalog_shas). The
    # web container's clones are only as fresh as its last boot.
    #
    # The snapshot carries HEAD plus each catalog's pinned ref as of the resolve
    # that wrote it; a ref pinned since then reads nil until the next refresh.
    # @param catalog_uri [String] e.g. "github://tadasant/zimmer-catalog"
    # @param ref [String] "HEAD" for the default branch, or a pinned ref
    # @return [String, nil] full commit SHA, or nil if the snapshot has none
    def resolved_sha_for(catalog_uri, ref: "HEAD")
      prefix = github_prefix(catalog_uri)
      return nil unless prefix

      ensure_loaded
      @catalog_shas&.dig(prefix, ref)
    rescue CatalogError
      nil
    end

    # The directory containing air.json — preserved for callers that still
    # reference it (e.g. AirPrepareService uses air_json_path to set AIR_CONFIG).
    def air_json_dir
      File.dirname(air_json_path)
    end

    # Re-invoke `air resolve --json` against this process's disk, serve the
    # result and store it as the new snapshot. Does NOT fetch upstream provider
    # data — use refresh! for that.
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

    # The most recent failed resolve, or nil when the last resolve succeeded.
    #
    # This is deliberately broader than degraded?, which is only true when a
    # last-known-good tree was available to fall back on. The case degraded?
    # cannot see is the worst one: a resolve failure with no fallback at all, where
    # load! re-raises and every config facade rescues CatalogError to an empty
    # array. That renders the session form as a full set of empty pickers —
    # indistinguishable from a fresh install with nothing configured. This flag is
    # recorded on *every* failure so the form can say which of the two it is.
    #
    # Process-local, like the rest of the in-memory cache: it describes what this
    # process last saw, and is cleared the moment a resolve succeeds.
    #
    # :message is `air resolve`'s own text with every credential this process
    # holds replaced by a `[REDACTED:NAME]` marker — see #record_failure.
    #
    # @return [Hash{Symbol => Object}, nil] :message and :at, or nil when healthy
    def resolve_failure
      @resolve_failure
    end

    # Replace every credential this process holds with a named marker, so an
    # operator still sees *which* credential the error framed rather than a hole
    # in the string.
    #
    # Public because the banner is not the only surface that renders an AIR
    # subprocess's own words back to a browser: "Catalog refresh failed: …"
    # (CatalogsController) lands on that same unauthenticated /sessions/new, and
    # the pin flash (CatalogPinsController) carries an `air resolve` failure onto
    # /settings. Every one of those strings came from a process holding
    # AIR_GITHUB_TOKEN, so they all go through here (#319).
    #
    # Deliberately hand-rolled rather than delegating to TranscriptRedactor,
    # whose known-value tier would be the better table: building that table calls
    # ServersConfig.all, which reads the catalog through this very service — so
    # from inside load!'s rescue it would re-enter load! on a still-broken
    # catalog. A redactor that can recurse through the failure it is redacting is
    # worse than a narrower one.
    #
    # @param text [String, nil]
    # @return [String, nil] the text with known credentials replaced
    def redact_secrets(text)
      return text if text.nil?

      # Scrubbed before anything reads it. `Open3.capture3` tags a subprocess's
      # stderr UTF-8 without validating it, and a mis-encoded path or remote name
      # in a git error is enough to make String#blank? (and the view's own
      # truncate) raise ArgumentError on the byte sequence. TranscriptRedactor
      # answers the same problem the same way.
      text = text.to_s
      text = text.scrub("") unless text.valid_encoding?
      return text if text.blank?

      redactable_secrets.reduce(text) do |scrubbed, (name, value)|
        # Block form: a `\0` in the name would otherwise be a backreference that
        # writes the credential back into the output.
        scrubbed.gsub(value) { "[REDACTED:#{name}]" }
      end
    rescue => e
      # Withhold rather than fall through to the raw string: the whole point of
      # this path is that the text may carry a credential, and a scrub that did
      # not run is not evidence that it does not. The unscrubbed text is still in
      # the application logs for an operator who can reach them.
      Rails.logger.warn "[AirCatalogService] could not scrub credentials from an AIR error: #{e.class}: #{e.message}"
      "the error text is withheld here because the credentials needed to scrub it could not be read " \
        "(#{e.class}); it is in the application logs"
    end

    # Pull latest provider caches (github clones) via `air update`, then reload
    # the in-memory entry tree. This is the "pull latest catalog" operation
    # invoked by CatalogRefreshJob and the manual refresh endpoint.
    def refresh!
      raise CatalogError, "air.json not found at #{air_json_path}" unless File.exist?(air_json_path)

      run_air_update!
      reload!
      true
    rescue CatalogError => e
      # A refresh that dies before reload! never reaches load!'s rescue, so record
      # the failure here too — otherwise "Refresh catalogs" can fail while the
      # session form still shows a healthy catalog.
      record_failure(e.message)
      raise
    end

    # When the provider clones behind the served catalog were last fetched — the
    # "Updated X ago" indicator. The writer read it off its own FETCH_HEAD
    # mtimes at resolve time (see local_fetched_at) and stored it on the
    # snapshot, so a process that never fetches still reports the fetch its
    # catalog came from. nil when that writer had no github clones.
    def last_refreshed_at
      ensure_loaded
      @fetched_at
    rescue CatalogError
      nil
    end

    # Serve the newest snapshot now, without waiting out the in-memory TTL. The
    # "Refresh catalogs" button calls this after the worker's refresh finishes,
    # so the page it redirects to shows the catalog that refresh just stored.
    # Resolves locally only when there is no snapshot at all.
    # @return [Boolean] false when there was nothing to serve and the resolve failed
    def sync_from_snapshot!
      load! unless sync_from_snapshot
      true
    rescue CatalogError
      false
    end

    # True when this process's provider clones were fetched before the ones the
    # served snapshot was resolved from.
    #
    # Serving the catalog needs no disk, but `air prepare` does: it materializes
    # skills and hooks out of this process's own ~/.air/cache. On the worker the
    # cron keeps that cache fresh, but a fork or an unarchive runs `air prepare`
    # on the web container, whose cache is only as fresh as its last boot.
    # AirPrepareService asks this first and fetches when it is behind, so a
    # skill the snapshot already lists is on disk by the time AIR looks for it.
    # Compared to the second, because the two sides are mtimes from different
    # containers and a database round trip truncates sub-second precision.
    def disk_cache_behind_snapshot?
      ensure_loaded
      return false unless @fetched_at

      local = local_fetched_at
      local.nil? || local.to_i < @fetched_at.to_i
    rescue CatalogError
      false
    end

    # Find the local clone path for a given github repo URL.
    # Used by WarmSkillsCacheJob to locate cached clones for repo-native skill
    # discovery. Scans the AIR github cache directory (~/.air/cache/github/
    # <owner>/<repo>/<ref>) for a matching repo.
    #
    # Deliberately reads this process's disk rather than the snapshot: it wants
    # a clone to read files from, which a snapshot cannot carry. Its only caller
    # runs on the worker, whose cache the cron keeps fresh.
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
      @resolve_failure = nil
      @snapshot_id = nil
      @fetched_at = nil
      @catalog_shas = nil
    end

    # Test/dev hook: install an already-resolved tree as the in-memory cache
    # without shelling out to the CLI.
    #
    # The test suite resolves the catalog once at boot and re-installs that
    # snapshot before every test, so no test inherits a cold cache (which sends
    # the next Session write straight to `air resolve`) or a stubbed fake one
    # from whatever ran before it in the same worker. See
    # test/support/air_catalog_cache_warmer.rb.
    #
    # This serves the tree the way a successful resolve does, with two deliberate
    # differences: it writes no CatalogSnapshot, because a tree handed in by a
    # caller is not evidence of a healthy catalog; and it drops the effective-path
    # memo, because the caller may have moved air_json_path since it was computed.
    def seed_cache!(entries)
      @entries = entries
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @last_known_good_at = Time.current
      @degraded = false
      @resolve_failure = nil
      @effective_path = nil
      @effective_fingerprint = nil
      @snapshot_id = nil
      @fetched_at = nil
      @catalog_shas = nil
    end

    private

    # Serve from memory within the TTL; past it, serve the newest snapshot, and
    # resolve locally only when there is no snapshot to serve.
    def ensure_loaded
      return unless @entries.nil? || expired?

      load! unless sync_from_snapshot
    end

    # Bring this process up to the newest persisted snapshot. Reads the header
    # (no tree) and loads the tree only for a row newer than the one served.
    #
    # Returns true when the snapshot table now governs what is served — it was
    # adopted, it is already being served, or it is older than a tree this
    # process resolved itself and failed to persist. Returns false when there is
    # no snapshot at all, which sends the caller to a local resolve (a first
    # boot, or a test that controls the table).
    #
    # A database error keeps serving the in-memory tree for another TTL rather
    # than falling back to a resolve: the tree in memory is the fleet's last
    # snapshot, and a local resolve could only be staler.
    def sync_from_snapshot
      header = CatalogSnapshot.latest_header
      return false unless header

      if header.id != @snapshot_id && newer_than_served?(header)
        snapshot = CatalogSnapshot.find_by(id: header.id) || CatalogSnapshot.latest
        return false unless snapshot

        adopt_snapshot(snapshot)
        header = snapshot
      end

      mirror_snapshot_health(header) if header.id == @snapshot_id
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      true
    rescue ActiveRecord::ActiveRecordError => e
      return false if @entries.nil?

      Rails.logger.warn "[AirCatalogService] could not read the catalog snapshot (#{e.class}: #{e.message}); " \
        "serving the in-memory catalog for another #{CATALOG_CACHE_TTL}s"
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      true
    end

    def newer_than_served?(header)
      @entries.nil? || @last_known_good_at.nil? || header.resolved_at > @last_known_good_at
    end

    # Serve a persisted snapshot's tree and the provenance that came with it.
    def adopt_snapshot(snapshot)
      @entries = entries_from_snapshot(snapshot.entries)
      @snapshot_id = snapshot.id
      @last_known_good_at = snapshot.resolved_at
      @fetched_at = snapshot.fetched_at
      @catalog_shas = snapshot.catalog_shas || {}
    end

    # Take degraded? and resolve_failure from the snapshot being served, so a
    # process that never resolves reports a refresh that failed elsewhere.
    #
    # Logged at .info, never .error: the process whose refresh failed already
    # alerted on its own healthy→degraded transition (log_degraded, or
    # CatalogRefreshJob), and every web and worker process echoing it at .error
    # would page once per process for one failure.
    def mirror_snapshot_health(snapshot)
      failure = snapshot.failure
      if failure && !@degraded
        Rails.logger.info "[AirCatalogService] the last catalog refresh failed (#{failure[:message]}); serving " \
          "the snapshot resolved at #{@last_known_good_at&.iso8601} as last-known-good"
      elsif !failure && @degraded
        Rails.logger.info "[AirCatalogService] catalog snapshot is healthy again; no longer degraded"
      end
      @degraded = failure.present?
      @resolve_failure = failure
    end

    def expired?
      @loaded_at &&
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @loaded_at) > CATALOG_CACHE_TTL
    end

    # Resolve the catalog tree and cache it in memory. On success, persist a
    # last-known-good snapshot. On any CatalogError (collision hard-fail, network
    # failure, broken install, missing air.json), fall back to the last-known-good
    # tree — in-memory first, then the persisted snapshot — so a broken upstream
    # catalog cannot take session creation (and the router-root lookup behind every
    # routable message) down to an empty catalog. Only re-raises when there is no
    # fallback at all (first-ever boot with a broken catalog).
    def load!
      raise CatalogError, "air.json not found at #{air_json_path}" unless File.exist?(air_json_path)

      parsed = parse_resolve_output(run_air_resolve!)
      entries = normalize_parsed(parsed)
      reject_empty_resolve!(entries)
      store_loaded_entries(entries)
    rescue CatalogError => e
      # Recorded before serve_last_known_good!, which re-raises when there is no
      # fallback — the one path where degraded? never gets set and the pickers go
      # silently empty.
      record_failure(e.message)
      serve_last_known_good!(e)
    end

    # Record a failed resolve for the session form's banner, with every
    # credential this process holds scrubbed out of the message first.
    #
    # The banner renders this string on /sessions/new, which has no Rails-layer
    # authentication (#312), under copy inviting an operator to paste it into a
    # bug report — and the process that produced it is handed AIR_GITHUB_TOKEN
    # by #provider_credentials_env. `air resolve` is not known to echo its
    # environment, so this closes a rendering surface rather than an observed
    # leak (#319).
    #
    # Scrubbed at the record site, not in the view: resolve_failure has more
    # than one reader, and a message that never carries a credential into memory
    # cannot be rendered by a reader that forgets to ask.
    #
    # Also written onto the newest snapshot, which is how every other process
    # learns of it (mirror_snapshot_health). Inside the pin controller's
    # transaction that write rolls back with the pins, so a rejected pin does
    # not mark the fleet's catalog degraded.
    def record_failure(message)
      @resolve_failure = { message: redact_secrets(message.to_s), at: Time.current }
      CatalogSnapshot.record_failure!(@resolve_failure[:message], at: @resolve_failure[:at])
    rescue => e
      Rails.logger.warn "[AirCatalogService] could not record the catalog failure on the snapshot: #{e.class}: #{e.message}"
    end

    # Credential values that could reach an AIR subprocess's stderr, longest
    # first so a value containing another is replaced whole rather than shredded
    # from the inside out.
    #
    # Two tiers, because the exposure has two halves:
    #
    #   1. SecretsLoader.all — Zimmer's own secret set. `air prepare` merges all
    #      of it into its subprocess env, and #provider_credentials_env takes
    #      AIR_GITHUB_TOKEN from it for `air resolve` / `air update`.
    #   2. Credential-named process ENV — every AIR subprocess inherits this
    #      process's whole environment through Open3, which is what an echoed
    #      environment would print. In production that is SECRET_KEY_BASE,
    #      RAILS_MASTER_KEY, DATABASE_PASSWORD, the operator SSH key, the
    #      Parameter Store service-account keys — none of them in tier 1, all of
    #      them in the child's env. It is also how an operator-set
    #      AIR_GITHUB_TOKEN (CI) reaches the resolve that never merges it.
    #
    # Filtered by name (TranscriptRedactor::SENSITIVE_KEY) rather than scrubbing
    # every environment variable, and each value has to look like a credential
    # rather than like prose — the same three conditions TranscriptRedactor puts
    # on a known value, for the same reason: replacing a short, spaced or
    # ordinary-word value would shred the error rather than protect anything.
    #
    # @return [Array<Array(String, String)>] [name, value] pairs
    def redactable_secrets
      candidates = SecretsLoader.all.to_a +
        ENV.select { |name, _value| name.match?(TranscriptRedactor::SENSITIVE_KEY) }.to_a
      candidates
        .select { |_name, value| redactable_value?(value) }
        .uniq { |_name, value| value }
        .sort_by { |_name, value| -value.length }
    end

    # A value only earns exact-match replacement if replacing every occurrence of
    # it cannot plausibly destroy ordinary error text.
    def redactable_value?(value)
      value.is_a?(String) &&
        value.length >= TranscriptRedactor::MIN_KNOWN_SECRET_LENGTH &&
        value.match?(/\A\S+\z/) &&
        !value.match?(/\A(?:true|false|null|none|\d+)\z/i)
    end

    # A resolve that found nothing of any type is a failed resolve, whatever the
    # exit code said.
    #
    # The dropped-reference check in run_air_resolve! only catches a resolve that
    # found index files and could not resolve every reference *between* their
    # entries. A resolve pointed at a config whose index paths do not exist finds
    # no index files at all: nothing is dropped, nothing is printed, AIR exits 0,
    # and the tree is legitimately, completely empty. That is exactly what a
    # relocated config with unfollowed relative paths produced (#1078), and the
    # silence was at the one layer built to catch it — `degraded?` stayed false
    # and the empty tree was persisted over the last-known-good snapshot.
    #
    # Raising routes load! into serve_last_known_good!, so an empty resolve
    # serves the previous catalog and flags degraded rather than overwriting it.
    # With no fallback to serve, the CatalogError surfaces on the settings /
    # session-form failure banner (every *Config reader rescues it to []) —
    # still empty pickers, but with a stated reason instead of none. A catalog
    # this empty cannot create a session either way; the only question is
    # whether anyone is told. Adjacent to #66, which is about the *other*
    # detector: the brittleness of matching AIR's stderr wording.
    def reject_empty_resolve!(entries)
      return if entries.any? { |_type, of_type| of_type.present? }

      raise CatalogError, "air resolve exited 0 but returned no artifacts of any type " \
        "(#{ARTIFACT_TYPES.join(", ")}) from #{air_json_path}, indicating a catalog whose declared " \
        "index files were not found"
    end

    # Cache a freshly resolved tree, persist it — with the fetch time and SHAs
    # of the disk it was resolved from — as the new snapshot, and clear any
    # degraded state.
    def store_loaded_entries(entries)
      Rails.logger.info "[AirCatalogService] catalog resolution recovered; serving freshly resolved catalog" if @degraded
      fetched_at = local_fetched_at
      catalog_shas = local_catalog_shas
      snapshot = persist_snapshot(entries, fetched_at: fetched_at, catalog_shas: catalog_shas)

      @entries = entries
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @snapshot_id = snapshot&.id
      @last_known_good_at = snapshot&.resolved_at || Time.current
      @fetched_at = fetched_at
      @catalog_shas = catalog_shas
      @degraded = false
      @resolve_failure = nil
    end

    # Serve the last-known-good catalog after a failed resolve. Prefers the
    # in-memory tree (a prior success in this process), then the persisted
    # snapshot (survives restarts, shared across web + worker). Re-raises only
    # when neither exists. Refreshes @loaded_at so we serve the stale tree for a
    # full TTL before retrying, rather than re-shelling out on every request.
    def serve_last_known_good!(error)
      source =
        if @entries.present?
          :memory
        elsif (snapshot = CatalogSnapshot.latest)
          adopt_snapshot(snapshot)
          :snapshot
        end

      unless source
        Rails.logger.error "[AirCatalogService] air resolve failed (#{error.message}) and no last-known-good " \
          "snapshot exists; catalog is unavailable and session creation will fail until resolution succeeds."
        raise error
      end

      log_degraded(error, source, @last_known_good_at)
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

    # Persist the resolved tree as the new snapshot. A snapshot-write failure
    # must never break catalog resolution, so DB errors are swallowed (logged at
    # .warn) rather than propagated. Returns the stored record, or nil.
    def persist_snapshot(entries, fetched_at:, catalog_shas:)
      CatalogSnapshot.store!(entries, fetched_at: fetched_at, catalog_shas: catalog_shas)
    rescue => e
      Rails.logger.warn "[AirCatalogService] failed to persist catalog snapshot: #{e.class}: #{e.message}"
      nil
    end

    # When this process last fetched its provider clones, from FETCH_HEAD mtimes
    # so the value survives restarts. nil when there are no github clones.
    def local_fetched_at
      return nil unless File.directory?(GITHUB_CACHE_DIR)

      Dir.glob(File.join(GITHUB_CACHE_DIR, "**", ".git", "FETCH_HEAD"))
        .filter_map { |p| File.mtime(p) if File.exist?(p) }
        .max
    end

    # The commit each pinnable catalog points at on this process's disk, for
    # HEAD and for its currently pinned ref — exactly the two refs the settings
    # page asks resolved_sha_for about. Recorded on the snapshot so every
    # process can answer without a clone of its own.
    # @return [Hash{String => Hash{String => String}}] catalog => { ref => sha }
    def local_catalog_shas
      pins = CatalogPin.as_map
      pinnable_catalogs.each_with_object({}) do |catalog, shas|
        by_ref = [ "HEAD", pins[catalog] ].compact_blank.uniq.filter_map do |ref|
          sha = local_sha(catalog, ref)
          [ ref, sha ] if sha
        end.to_h
        shas[catalog] = by_ref if by_ref.any?
      end
    rescue => e
      Rails.logger.warn "[AirCatalogService] could not read catalog SHAs from the provider cache: #{e.class}: #{e.message}"
      {}
    end

    def local_sha(catalog_uri, ref)
      owner, repo = github_owner_repo(catalog_uri)
      return nil unless owner

      clone_dir = File.join(GITHUB_CACHE_DIR, owner, repo, ref)
      return nil unless File.directory?(File.join(clone_dir, ".git"))

      stdout, _stderr, status = Open3.capture3("git", "-C", clone_dir, "rev-parse", "HEAD")
      sha = stdout.to_s.strip
      SubprocessStatus.success?(status) && sha.match?(/\A\h{40,64}\z/) ? sha : nil
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

      stdout, stderr, status = capture_air(air_env, air_binary, "resolve", "--json", "--no-scope", "--git-protocol", "https")
      unless SubprocessStatus.success?(status)
        raise CatalogError, "air resolve failed (#{SubprocessStatus.describe_failure(status)}): #{stderr.presence || stdout}"
      end

      # A resolve can exit 0 yet be structurally incomplete. When a catalog
      # source is stale, partially fetched, or missing, AIR cannot resolve every
      # declared reference, so it drops the unresolvable ones and emits
      # "references unknown ... Dropping the reference" warnings on stderr while
      # still exiting 0. The dropped references are exactly what strips affected
      # roots' default_skills / default_mcp_servers / default_hooks — including
      # the router root's defaults behind every chat_bubble / quick_prompt session.
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

      stdout, stderr, status = capture_air(air_env, air_binary, "update", "--git-protocol", "https")
      unless SubprocessStatus.success?(status)
        raise CatalogError, "air update failed (#{SubprocessStatus.describe_failure(status)}): #{stderr.presence || stdout}"
      end
      Rails.logger.info "[AirCatalogService] air update: #{stdout.strip}" if stdout.present?
    end

    # Spawn the AIR binary, converting an unreachable one into CatalogError.
    #
    # A binary that exits non-zero comes back as a failed status and is handled
    # by the callers above; a binary that is not there at all raises
    # Errno::ENOENT out of the spawn itself, which is a SystemCallError and so
    # slips past every `rescue CatalogError` between here and the view. That is
    # how a missing AIR CLI reached a session-card render as an
    # ActionView::Template::Error and killed the job around it, instead of
    # degrading to the last-known-good catalog like every other resolve failure
    # (GlitchTip #61, 2026-09-01). The install path takes care not to remove the
    # binary (see AirPrepareService#swap_staged_install!), but "the file is
    # gone" is a state this service should survive however it arises.
    def capture_air(*command)
      stdout, stderr, status = Open3.capture3(*command)
      # Open3 tags a subprocess's output UTF-8 without validating it, and a
      # mis-encoded path or remote name in a git error is enough to make every
      # ActiveSupport string predicate downstream — `stderr.presence` in
      # #run_air_resolve!, `blank?` in .redact_secrets, `truncate` in the banner —
      # raise ArgumentError on the byte sequence. That ArgumentError is not a
      # CatalogError, so it would escape load!'s rescue rather than degrading to
      # the last-known-good catalog.
      [ scrub_bytes(stdout), scrub_bytes(stderr), status ]
    rescue SystemCallError => e
      raise CatalogError, "could not run the AIR CLI (#{e.class}: #{e.message})"
    end

    def scrub_bytes(output)
      return output unless output.is_a?(String)
      output.valid_encoding? ? output : output.scrub("")
    end

    # Lazy-install AIR CLI on first use. Converts AirPrepareError to CatalogError
    # so callers that rescue CatalogError get a consistent failure mode.
    def ensure_air_cli!
      AirPrepareService.ensure_air_installed!
    rescue AirPrepareService::AirPrepareError => e
      raise CatalogError, "AIR CLI installation failed: #{e.message}"
    rescue SystemCallError => e
      # Belt-and-braces for a future install operation that has not yet been
      # normalized by AirPrepareService. Catalog availability must degrade to a
      # snapshot, never depend on the exact Errno subclass an installer leaked.
      raise CatalogError, "AIR CLI installation failed (#{e.class}: #{e.message})"
    end

    def air_binary
      File.join(AirPrepareService::AIR_INSTALL_DIR, "node_modules", ".bin", "air")
    end

    def air_env
      { "AIR_CONFIG" => effective_air_json_path }.merge(provider_credentials_env)
    end

    # Credentials the AIR CLI needs in its *process* environment while composing
    # the catalog — as opposed to the ${VAR} placeholders that air-secrets-env
    # substitutes into entries at `air prepare` time.
    #
    # The only such credential today is AIR_GITHUB_TOKEN: the air-provider-github
    # extension reads it from the resolve/update subprocess's ENV to authenticate
    # its fetch of any private `github://…` catalog source declared in air.json.
    # Zimmer already carries this token in mcp_secrets (encrypted credentials).
    # The `air prepare` path (AirPrepareService) already merges *all* of
    # SecretsLoader.all into its subprocess env, so the provider is authenticated
    # there — but the resolve/update path built a minimal AIR_CONFIG-only env and
    # merged no secrets at all. So the `air resolve` / `air update` fetch ran
    # tokenless, 401'd on the private repo, and AIR silently dropped the source
    # (leaving only the locally indexed servers), so none of the github-composed
    # MCP servers appeared in the resolved catalog / get_configs.
    #
    # Scoped deliberately to just this one token rather than all of
    # SecretsLoader.all: unrelated mcp_secrets are meant to stay ${VAR}
    # placeholders in the resolved tree (which we cache in CatalogSnapshot and
    # surface via get_configs / the settings UI), and must never be materialized
    # into that output. Only merged when present, so an operator-set process-env
    # AIR_GITHUB_TOKEN (e.g. CI) still passes through via Open3's env inheritance.
    def provider_credentials_env
      token = SecretsLoader.get("AIR_GITHUB_TOKEN")
      token.present? ? { "AIR_GITHUB_TOKEN" => token } : {}
    rescue => e
      # A credentials read failure must never take down catalog resolution; fall
      # back to whatever the process env already carries.
      Rails.logger.warn "[AirCatalogService] could not load AIR_GITHUB_TOKEN from secrets: #{e.class}: #{e.message}"
      {}
    end

    # Rewrite the base air.json with the pin set and persist it to tmp/. Returns
    # the path to the generated file — or the base path itself when the pins
    # changed nothing.
    #
    # Two guards, both of them the difference between a pin narrowing the
    # catalog and a pin emptying it (#1078):
    #
    #   1. **A pin that matches nothing leaves resolution exactly as it was**, so
    #      `relocated` returns nil and no copy is written. `CatalogPin` rows are
    #      not validated against the catalogs the config declares —
    #      `/supervisor/catalog_pins` is full Administrate CRUD over
    #      `[:catalog, :ref]` — so a row naming a catalog this air.json never
    #      mentions is writable, and used to switch every process onto a copy
    #      for no reason at all.
    #   2. **The copy carries absolute source paths.** AIR resolves a config's
    #      local index paths relative to the config file's own directory, and
    #      both air.json and air.production.json declare relative ones
    #      (`"skills": ["./skills/skills.json"]` and five siblings). Written
    #      into tmp/ unchanged, those resolve to tmp/skills/skills.json — which
    #      does not exist, so `air resolve` exits 0 with an empty catalog and
    #      every subsequent session creation fails agent_root validation.
    #
    # Absolute paths rather than writing the copy beside the base config: tmp/
    # is the one directory this process is guaranteed to be able to write (an
    # operator can point AIR_CONFIG at a read-only mount), and the process-unique
    # filename below only makes sense somewhere ephemeral.
    def generate_effective_config(base_path, pins)
      raise CatalogError, "air.json not found at #{base_path}" unless File.exist?(base_path)

      relocatable = AirCatalogRefRewriter.relocated(
        File.read(base_path), pins: pins, base_dir: File.dirname(base_path)
      )
      if relocatable.nil?
        Rails.logger.info "[AirCatalogService] catalog pins (#{pins.keys.join(", ")}) matched no catalog " \
          "declared in #{base_path}; resolving the catalog unrewritten."
        return base_path
      end

      out_path = effective_config_path
      FileUtils.mkdir_p(out_path.dirname)
      File.write(out_path, relocatable)
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
    # This is the same class of shared-tmp-file race that issue pulsemcp/pulsemcp#3455/#3741 hit
    # for FileStorageService; keep the path process-unique. See issue pulsemcp/pulsemcp#4113.
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
