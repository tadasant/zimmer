# frozen_string_literal: true

# Which repositories WarmClonePool keeps ready clones of, and how many of each.
#
# == Two scopes
#
# `router` — the router root's repository, one clone (QUICK_ROUTER_WARM_CLONES),
# served to router sessions only. This is the pool as it first shipped.
#
# `active` — every (repository, branch) that a catalog agent root started
# sessions on in the trailing WINDOW, ranked by those starts with recent ones
# weighted more, until the clones would pass the global cap. Served to any
# session whose `git_root` and `branch` are a pooled key. The router's key is
# always first, so `active` never serves the router worse than `router` does.
#
# The scope is the Settings → Experimental toggle
# `warm_clone_pool_active_roots_enabled`, off by default.
#
# == Why keys, not roots
#
# A clone is of a repository at a branch; which subdirectory a root lives in is
# resolved after the claim. About twenty of the Tadasant deployment's active
# roots are subdirectories of one repository on `main`, so one key serves all of
# them. Roots are therefore counted, mapped to their catalog (url, branch), and
# summed per key. A deprecated router alias (`zimmer-router`) counts toward the
# router, and a root that has left the catalog counts toward nothing.
#
# == What it costs
#
# Every pooled clone is rebuilt about every 45 minutes (WarmClonePool's recycle),
# so each one is roughly 32 clones a day from the git host whether or not anyone
# claims it. MIN_STARTS keeps a repository that sees a start a week out of the
# pool, and MAX_CLONES bounds the whole. Disk is guarded per build by
# WarmClonePool.room_to_build?, which never lets the pool compete with the
# sessions' own clones; keys are built in rank order, so a short disk drops the
# least-used keys first.
#
# The ranking is a grouped query over a week of sessions. It is cached for
# CACHE_TTL, because `serves?` asks for it on every session start.
module WarmPoolPolicy
  SCOPES = %w[router active].freeze

  # How far back session starts count.
  WINDOW = 7.days

  # A start this long ago counts half as much as one now.
  HALF_LIFE = 2.days

  # Starts in WINDOW below which a key is not worth a clone rebuilt ~32 times a day.
  MIN_STARTS = 7

  # Starts in WINDOW at which a key gets a second clone: about one an hour, the
  # rate at which two starts land within one refill of each other often enough
  # to matter.
  BUSY_STARTS = 150

  # Clones a busy key gets under `active`, unless QUICK_ROUTER_WARM_CLONES
  # already gives every key more.
  BUSY_SIZE = 2

  # A key that is pooled already stays pooled down to this many starts, and
  # ranks as though its score were INCUMBENT_BONUS times higher. Scores decay
  # continuously and the plan is rebuilt every CACHE_TTL, so without the margin a
  # key at MIN_STARTS or at the cap would drop in and out — and every drop deletes
  # its clones, which the next rise rebuilds from the git host.
  INCUMBENT_MIN_STARTS = 4
  INCUMBENT_BONUS = 1.25

  # The most clones `active` keeps altogether. WARM_CLONE_POOL_MAX_CLONES overrides.
  DEFAULT_MAX_CLONES = 10

  # How long a plan is reused. Also how long a catalog change — a root's url,
  # its default branch, which name the router answers to — takes to reach it.
  CACHE_TTL = 5.minutes

  # One pooled key.
  # `roots` is { root name => starts in WINDOW }, busiest first.
  Target = Data.define(:repo_url, :branch, :size, :roots, :starts, :score)

  module_function

  def scope
    AppSetting.current(context: "WarmPoolPolicy.scope").warm_clone_pool_active_roots_enabled? ? "active" : "router"
  end

  def active?
    scope == "active"
  end

  def max_clones
    configured = ENV["WARM_CLONE_POOL_MAX_CLONES"].presence
    return DEFAULT_MAX_CLONES if configured.nil?

    Integer(configured, 10).clamp(1, 30)
  rescue ArgumentError
    DEFAULT_MAX_CLONES
  end

  # The keys to keep clones of, in the order they are built.
  # @param base_size [Integer] WarmClonePool.size, the router-scope clone count
  # @param scope [String] the scope already read, so a caller that has one does
  #   not read the settings row twice
  # @return [Array<Target>]
  def targets(base_size:, scope: self.scope)
    return [] unless base_size.positive?

    plan(base_size: base_size, scope: scope)[:targets].map { |attrs| Target.new(**attrs) }
  end

  # Targets plus what was ranked and left out.
  #
  # `ranked: true` is the health report's: it ranks under `router` too, so the
  # report can show what `active` would pool before anyone turns it on. Every
  # other caller leaves it false, and under `router` the plan is then the router
  # root's catalog entry and nothing else — no query, as before the policy
  # existed, since `serves?` asks on every session start.
  #
  # @return [Hash] { scope:, max_clones:, targets: [Hash], passed_over: [Hash] }
  def plan(base_size:, scope: self.scope, ranked: false)
    ranked ||= scope == "active"
    Rails.cache.fetch([ "warm_pool_policy", scope, ranked, base_size, max_clones ], expires_in: CACHE_TTL) do
      build_plan(scope, base_size, ranked: ranked)
    end
  end

  def build_plan(current_scope, base_size, ranked: true, now: Time.current)
    roots = AgentRootsConfig.all
    router = router_target(roots, base_size)
    ranked = ranked ? rank(roots, now: now) : []

    targets = []
    passed_over = []
    clones = 0

    if router
      router_key = [ router[:repo_url], router[:branch] ]
      ranked_router = ranked.find { |t| [ t[:repo_url], t[:branch] ] == router_key }
      ranked -= [ ranked_router ] if ranked_router
      # Under `router` the key serves router sessions alone, so it is the router's
      # starts and the router's name that describe it; under `active` it serves
      # every root on the key, and is sized for all of them.
      if ranked_router && current_scope == "active"
        router = ranked_router.merge(size: size_for(ranked_router[:starts], base_size))
      elsif ranked_router
        router_starts = ranked_router[:roots].slice(*router[:roots].keys)
        router = router.merge(roots: router[:roots].merge(router_starts), starts: router_starts.values.sum)
      end
      targets << router
      clones += router[:size]
    end

    ranked.sort_by { |candidate| [ -effective_score(candidate), candidate[:repo_url], candidate[:branch] ] }.each do |candidate|
      candidate = candidate.except(:size)
      if candidate[:starts] < (pooled?(candidate) ? INCUMBENT_MIN_STARTS : MIN_STARTS)
        passed_over << candidate.merge(reason: "fewer than #{MIN_STARTS} starts in #{WINDOW.inspect}")
        next
      end

      if current_scope != "active"
        passed_over << candidate.merge(reason: "pooled only under the active scope")
        next
      end

      size = size_for(candidate[:starts], base_size)
      if clones + size > max_clones
        passed_over << candidate.merge(reason: "over the #{max_clones}-clone cap")
        next
      end

      targets << candidate.merge(size: size)
      clones += size
    end

    { scope: current_scope, max_clones: max_clones, targets: targets, passed_over: passed_over }
  end

  # The router root's key, exactly as the router-only pool always had it.
  def router_target(roots, base_size)
    root = ArtifactIdentity.find(roots, AgentRootsConfig.router_root_name)
    return nil if root.nil? || root.url.blank?

    { repo_url: root.url, branch: root.default_branch.presence || "main", size: base_size,
      roots: { root.name => 0 }, starts: 0, score: 0.0 }
  end

  # Whether the pool holds this key already. A directory listing, once per plan.
  def pooled?(candidate)
    Dir.exist?(WarmClonePool.key_dir(candidate[:repo_url], candidate[:branch]))
  end

  def effective_score(candidate)
    pooled?(candidate) ? candidate[:score] * INCUMBENT_BONUS : candidate[:score]
  end

  # Every catalog key that started a session in WINDOW, highest score first.
  def rank(roots, now:)
    by_key = {}

    starts_by_root_and_hour(now).each do |(root_name, hour), count|
      root = ArtifactIdentity.find(roots, canonical_root_name(root_name))
      next if root.nil? || root.url.blank?

      branch = root.default_branch.presence || "main"
      entry = by_key[[ root.url, branch ]] ||= { repo_url: root.url, branch: branch, size: 0, roots: Hash.new(0), starts: 0, score: 0.0 }
      entry[:roots][root.name] += count
      entry[:starts] += count
      entry[:score] += count * (0.5**((now - hour.to_time) / HALF_LIFE.to_f))
    end

    by_key.values.each do |entry|
      entry[:score] = entry[:score].round(2)
      entry[:roots] = entry[:roots].sort_by { |name, starts| [ -starts, name ] }.to_h
    end.sort_by { |entry| [ -entry[:score], entry[:repo_url], entry[:branch] ] }
  end

  # { [agent_root_key, hour] => sessions created }
  def starts_by_root_and_hour(now)
    Session.where(created_at: (now - WINDOW)..now)
           .where("metadata->>'agent_root_key' IS NOT NULL")
           .group(Arel.sql("metadata->>'agent_root_key'"), Arel.sql("date_trunc('hour', created_at)"))
           .count
  end

  def canonical_root_name(name)
    AgentRootsConfig::ROUTER_ROOT_NAMES.include?(name) ? AgentRootsConfig.router_root_name : name
  end

  def size_for(starts, base_size)
    starts >= BUSY_STARTS ? [ base_size, BUSY_SIZE ].max : base_size
  end
end
