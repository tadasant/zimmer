# frozen_string_literal: true

# A one-off memory boost for ONE session: a larger per-session `memory.max`, paid for out of
# the sessions pool, until it expires or the session is archived.
#
# WHY IT EXISTS
# -------------
# The defaults are conservative on purpose — 4 GiB per session, a 6 GiB pool for all of
# them, a 10 GiB container — and SessionMemoryCgroup's header carries why. Most work fits.
# Some does not: a session rebuilding a Rust desktop app (session 25433) was OOM-killed
# twice, and the human question was whether one session could have more, once, without
# loosening anything for everyone else.
#
# WHY A PER-SESSION LIMIT IS NOT ENOUGH
# -------------------------------------
# Both of 25433's kills were declared by the POOL: its own `oom` counter stayed at 0 while
# `oom_kill` reached 2, the signature SessionMemoryCgroup#kill_scope reads as "an ancestor
# ran out". It was nowhere near its own 4 GiB; the other sessions on the box held the rest
# of the pool. Raising its own bound alone would have changed nothing. A boost has to
# answer where the headroom comes from as well as how the session gets it.
#
# WHERE THE HEADROOM COMES FROM
# -----------------------------
# Not from widening the pool or the container. The pool's cap is root-owned precisely so
# the app cannot widen it (#981): it is what keeps a pile-up of sessions from reaching the
# container cap, where the kernel picks the Rails worker. Moving it is a deploy-config
# decision (ZIMMER_SESSIONS_MEMORY_MAX_MB, sized against the container's own cap), and a
# one-off has no business making it.
#
# So the boost is CARVED OUT of the pool. The boosted session's cgroup moves into the
# pool's `boosted` tier with a `memory.max` of the boost, and every other session — all in
# the `shared` tier — is capped together at what the boost leaves: pool minus boost. The
# kernel enforces the reservation, so it holds against sessions already running as well as
# ones that start later, and nothing on the scheduling path has to know about it. The pool,
# the container and the worker's margin are exactly what they were.
#
# The alternatives, and why not:
#   * Admission control — hold other sessions' turns while a boost runs. Holds only
#     sessions that have not started, so it cannot stop the ones already running from
#     growing into the boost, which is what killed 25433; and every hold path in Zimmer
#     is the spot gate's, which priority work never consults — the very sessions that
#     were running beside 25433.
#   * Making the boosted session the last OOM victim (`oom_score_adj` on everyone else).
#     Keeps the boost by killing other sessions' work when the pool fills, with nothing to
#     say why on their pages.
#   * `memory.min` on the boosted cgroup. Protects memory from RECLAIM, and anonymous
#     memory on a swapless worker is not reclaimable anyway; it has no say in which
#     process the OOM killer picks.
#
# WHAT IT COSTS, AND THE BOUNDS THAT FOLLOW
# -----------------------------------------
# Everyone else shares less, for as long as the boost is held. Hence:
#   * ONE boost at a time (Sessions::UpdateMemoryBoost refuses a second).
#   * SHARED_FLOOR_BYTES is always left to everyone else, so the boost actually granted is
#     at most pool minus 1 GiB — 5 GiB on a 6 GiB pool. A boost bigger than that is a
#     bigger pool, which is a deploy, not a toggle.
#   * It expires: MAX_HOURS at most, DEFAULT_HOURS unless asked otherwise, and the moment
#     the session is archived.
#   * The cap on everyone else is approached, never imposed: it is never written below
#     what they already hold (SessionMemoryCgroup.cap_shared!), so granting a boost on a
#     busy box kills nobody. The reservation is complete once they have freed enough, and
#     the session page says how much of it is in force.
#
# HOW IT IS APPLIED
# -----------------
# The web container has no cgroups, so the request (two columns on the session) and the
# enforcement are separate. #reconcile! runs on the worker — once a minute from
# SessionMemoryBoostJob, and at the spawn of a boosted session — and converges the cgroups
# on whatever the columns say: carve the boosted session out, cap `shared`, return a
# session whose boost has ended, lift the cap. Every step is idempotent, so a missed tick
# costs a minute and nothing else. What it applied is recorded on the session
# (APPLIED_* metadata keys), which is how the page and get_session can tell a boost that is
# in force from one that has only been asked for.
class SessionMemoryBoost
  MIB = 1024 * 1024

  # What every session other than the boosted one keeps, together, whatever the boost asks
  # for. A few idle sessions — an orchestrator asleep on its children, a session waiting on
  # CI — sit at a few hundred MB apiece, so 1 GiB keeps them alive; a boost that left them
  # nothing would turn every other session's next allocation into an OOM kill.
  SHARED_FLOOR_BYTES = 1024 * MIB

  # A sanity bound on what can be asked for. The boost actually granted is clamped to the
  # live pool (#effective_bytes), so this only refuses typos.
  MAX_MB = 16_384

  DEFAULT_HOURS = 6
  MAX_HOURS = 24

  # What #reconcile! last applied to a boosted session, in its system metadata.
  APPLIED_BYTES_KEY = "memory_boost_applied_bytes"
  SHARED_CAP_BYTES_KEY = "memory_boost_shared_cap_bytes"
  SHARED_TARGET_BYTES_KEY = "memory_boost_shared_target_bytes"
  APPLIED_AT_KEY = "memory_boost_applied_at"
  APPLIED_KEYS = [ APPLIED_BYTES_KEY, SHARED_CAP_BYTES_KEY, SHARED_TARGET_BYTES_KEY, APPLIED_AT_KEY ].freeze

  class << self
    # The smallest boost worth asking for: anything at or under the ordinary per-session
    # bound is not a boost.
    def min_mb
      (SessionMemoryCgroup.limit_bytes / MIB) + 1
    end

    # Converge the worker's cgroups on the boosts the database holds. Safe to call at any
    # time, from anywhere, as often as wanted; a container without session cgroups is a
    # no-op.
    #
    # @return [Hash{Integer => Integer}] session id => bytes granted, for the caller's log
    def reconcile!(now: Time.current)
      return {} unless enforcing?
      return {} unless SessionMemoryCgroup.available?
      return {} unless SessionMemoryCgroup.ensure_tier!(SessionMemoryCgroup.shared_path) &&
                       SessionMemoryCgroup.ensure_tier!(SessionMemoryCgroup.boosted_path)

      pool_limit = SessionMemoryCgroup.pool_stats.limit_bytes
      boosts = Session.holding_memory_boost(now).order(:id).to_a
      grants = grants_for(boosts, pool_limit)

      carved = grants.select { |session, bytes| SessionMemoryCgroup.new(session.id).carve_out!(bytes) }

      # The cap is settled BEFORE an ended boost's processes go back into `shared`, so they
      # never land under a cap that was sized for a boost that no longer exists.
      target = pool_limit && carved.any? ? pool_limit - carved.values.sum : nil
      shared_cap = SessionMemoryCgroup.cap_shared!(target)

      (SessionMemoryCgroup.boosted_session_ids - carved.keys.map(&:id)).each do |id|
        SessionMemoryCgroup.new(id).return_to_shared!
        clear_applied(Session.find_by(id: id))
      end

      # A cap that could not be written is not recorded as one: the page would otherwise
      # read "all of it is reserved" off a nil.
      carved.each { |session, bytes| record_applied(session, bytes, shared_cap, target, now) } unless target && shared_cap.nil?
      (boosts - grants.keys).each { |session| record_unpayable(session, pool_limit, now) }
      carved.to_h { |session, bytes| [ session.id, bytes ] }
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[SessionMemoryBoost] Reconcile failed: #{e.message}")
      {}
    end

    # Whether this process may converge the cgroup tree it can see.
    #
    # A dev boot inside a session (bin/agent-dev), and a test run, both happen on the
    # production worker, where the real tree is writable by the same uid — and their
    # databases know none of production's boosts. Reconciling from there would hand every
    # production boost back to the shared tier and lift the cap, once a minute. So only the
    # deployed environments converge the default tree; anything else must have been pointed
    # at a tree of its own (ZIMMER_SESSION_CGROUP_ROOT), which is what the tests do.
    def enforcing?
      return true if Rails.env.production? || Rails.env.staging?

      root = ENV["ZIMMER_SESSION_CGROUP_ROOT"].presence
      root.present? && root != SessionMemoryCgroup::DEFAULT_ROOT
    end

    # The largest boost this deployment's pool can pay for, in MB, read from the same
    # deploy-time setting bin/docker-entrypoint writes the pool's cap from. nil when that is
    # not configured here (development, test) or the pool is uncapped, in which case the
    # worker's live reading decides.
    def grantable_mb
      configured = Integer(ENV["ZIMMER_SESSIONS_MEMORY_MAX_MB"].presence || "", exception: false)
      return nil if configured.nil? || configured <= 0

      configured - (SHARED_FLOOR_BYTES / MIB)
    end

    # What one boost is actually worth on a pool of `pool_limit` bytes: what it asked for,
    # but never more than leaves SHARED_FLOOR_BYTES to everyone else. nil when that is no
    # more than the ordinary bound, which is no boost at all.
    #
    # @return [Integer, nil]
    def effective_bytes(requested_mb, pool_limit)
      requested = requested_mb.to_i * MIB
      granted = pool_limit ? [ requested, pool_limit - SHARED_FLOOR_BYTES ].min : requested
      granted > SessionMemoryCgroup.limit_bytes ? granted : nil
    end

    # One sentence about a session's boost, shared by the session page and get_session so
    # the two cannot describe it differently. nil when the session holds none.
    #
    # @param session [Session]
    # @return [String, nil]
    def describe(session, now: Time.current)
      return nil unless session.memory_boost_active?(now: now)

      requested = human_bytes(session.memory_boost_mb * MIB)
      until_clause = "until #{session.memory_boost_expires_at.utc.iso8601} or until the session is archived"
      applied = session.metadata&.dig(APPLIED_BYTES_KEY)
      return "#{requested} requested, #{until_clause}. Not applied yet — the worker applies it within a minute." if applied.blank?
      if applied.to_i.zero?
        return "#{requested} requested, #{until_clause}. Not applied: this worker's shared pool " \
          "(#{human_bytes(session.metadata[SHARED_TARGET_BYTES_KEY])}) cannot pay for any boost above the ordinary " \
          "#{human_bytes(SessionMemoryCgroup.limit_bytes)} and still leave the other sessions " \
          "#{human_bytes(SHARED_FLOOR_BYTES)}."
      end

      cap = session.metadata[SHARED_CAP_BYTES_KEY]
      target = session.metadata[SHARED_TARGET_BYTES_KEY]
      reservation = if target.nil?
        "the pool has no aggregate cap, so nothing else had to give way"
      elsif cap.to_i <= target.to_i
        "the other sessions are capped at #{human_bytes(target)} together, so all of it is reserved"
      else
        "the other sessions are capped at #{human_bytes(cap)} together, coming down to #{human_bytes(target)} " \
          "as they free memory, so #{human_bytes(applied.to_i - (cap.to_i - target.to_i))} of it is reserved so far"
      end
      clamp = applied.to_i < session.memory_boost_mb * MIB ? " (#{requested} requested; the pool leaves room for no more)" : ""
      "#{human_bytes(applied)} per-session limit#{clamp}, #{until_clause}; #{reservation}."
    end

    private

    # The boosts the pool can pay for, oldest session first. More than one is refused at
    # the door, but a race between two doors could store two, and the pool must not be
    # overspent when it does: a later boost gets what the earlier ones left, or nothing.
    def grants_for(sessions, pool_limit)
      budget = pool_limit
      sessions.each_with_object({}) do |session, grants|
        bytes = effective_bytes(session.memory_boost_mb, budget)
        next if bytes.nil?

        grants[session] = bytes
        budget -= bytes if budget
      end
    end

    # Written only when something changed, so a boost held for six hours is not a metadata
    # write — and a broadcast — every minute.
    def record_applied(session, bytes, shared_cap, target, now)
      values = { APPLIED_BYTES_KEY => bytes, SHARED_CAP_BYTES_KEY => shared_cap, SHARED_TARGET_BYTES_KEY => target }
      return if values.all? { |key, value| session.metadata&.dig(key) == value }

      session.merge_metadata!(values.merge(APPLIED_AT_KEY => now.iso8601))
    end

    # A boost the pool cannot pay for at all, recorded so the page says so instead of
    # "not applied yet" until it expires. The pool's size rides in the target key.
    def record_unpayable(session, pool_limit, now)
      record_applied(session, 0, nil, pool_limit, now)
    end

    # What the session was told about a boost it no longer holds. Public for
    # Sessions::UpdateMemoryBoost and the archive hook, which start or end a boost and must
    # not leave the previous one's "applied" reading behind for the page to show.
    public def clear_applied(session)
      return if session.nil? || APPLIED_KEYS.none? { |key| session.metadata&.key?(key) }

      session.remove_metadata!(*APPLIED_KEYS)
    end

    def human_bytes(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes)
    end
  end
end
