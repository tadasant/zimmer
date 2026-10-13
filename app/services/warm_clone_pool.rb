# frozen_string_literal: true

require "digest"
require "fileutils"

# A standing pool of ready-made clones of the router root's repository, so a
# Quick Router request does not wait on a `git clone`.
#
# == Why the clone, and only the clone
#
# Measured across a dozen router sessions in October 2026, a Quick Router
# request took a median ~19.5s from creation to the router's first model
# output. The full single-branch clone of the router's repository was ~13s of
# that (9.6–28s). `air prepare`, the OAuth gate and the system prompt together
# were under a second; Claude Code's boot and MCP handshake ~2s; the first model
# token ~2s. The clone is the one step that is both slow and carries nothing
# about the request, so it is the one step worth doing ahead of time.
#
# Everything per-request still runs on claim, exactly as on the cold path:
# `air prepare` for the session's runtime and artifacts, secrets, OAuth, the
# system prompt, the spawn. So model, runtime, spot class and attachments are
# untouched, and no session row, agent process or Claude quota exists for a
# clone sitting in the pool — it holds no fleet slot and never reaches the
# homepage action queue.
#
# == Layout and the claim
#
#   <clones base>/.warm-clones/<key>/<epoch>-<hex>        a ready clone
#   <clones base>/.warm-clones/<key>/.building-<epoch>-<hex>   one being made
#
# The pool lives under a dot-prefixed directory because the orphan sweep skips
# dot entries; a pooled clone has no owning session by design. A ready entry is
# only ever created by renaming a finished build into place, and is claimed by
# renaming it onto the session's own clone path. `rename` is atomic on one
# filesystem, so of two requests racing for one entry exactly one gets it and
# the other moves on to the next entry, or to the cold path.
#
# A claimed clone is then fetched to the branch tip, so it is as fresh as a cold
# clone would have been. A fetch that fails discards the claimed clone and the
# caller clones cold, which is today's behaviour.
#
# == Replenishment
#
# WarmClonePoolReplenishJob refills the pool: enqueued on every claim, and on a
# one-minute cron as the backstop that converges after a deploy, a failed build
# or a race. Entries older than MAX_AGE are recycled, so a fetch on claim stays
# a few commits deep rather than a day's worth.
module WarmClonePool
  DIRNAME = ".warm-clones"
  BUILDING_PREFIX = ".building-"

  # How old a ready clone may get before it is recycled rather than claimed.
  # Also keeps the claim's catch-up fetch small.
  MAX_AGE = 1.hour

  # A build that has not finished in this long died with its worker.
  ABANDONED_BUILD_AGE = 30.minutes

  # The catch-up fetch runs on the request's critical path. A fetch that takes
  # longer than this is a sign GitHub is struggling, and the cold path is no
  # worse a bet.
  FETCH_TIMEOUT_SECONDS = 20

  # Deployed environments only by default: a development machine or the test
  # suite has no business cloning the router's repository in the background.
  DEPLOYED_ENVIRONMENTS = %w[production staging].freeze

  module_function

  # Ready clones to keep per target. `QUICK_ROUTER_WARM_CLONES` overrides the
  # default (1 when deployed, 0 elsewhere); 0 turns the pool off, so nothing is
  # built and nothing is claimed.
  def size
    configured = ENV["QUICK_ROUTER_WARM_CLONES"].presence
    return default_size if configured.nil?

    Integer(configured, 10).clamp(0, 5)
  rescue ArgumentError
    default_size
  end

  def default_size
    DEPLOYED_ENVIRONMENTS.include?(Rails.env.to_s) ? 1 : 0
  end

  def enabled?
    size.positive?
  end

  # Whether a session's fresh start should try the pool: sessions on the router
  # root, which is what every Quick Router entry point creates.
  def serves?(session)
    enabled? && AgentRootsConfig::ROUTER_ROOT_NAMES.include?(session.metadata&.dig("agent_root_key"))
  end

  # The repositories the pool keeps clones of: the router root's.
  # @return [Array<Array(String, String)>] [repo_url, branch] pairs
  def targets
    root = AgentRootsConfig.find(AgentRootsConfig.router_root_name)
    return [] if root.nil? || root.url.blank?

    [ [ root.url, root.default_branch.presence || "main" ] ]
  end

  def root_dir
    File.join(ClonesDirectory.base, DIRNAME)
  end

  def key(repo_url, branch)
    digest = Digest::SHA256.hexdigest("#{repo_url}\n#{branch}")[0, 12]
    "#{File.basename(repo_url.to_s, '.git')}-#{branch.to_s.tr('/', '-')}-#{digest}"
  end

  def key_dir(repo_url, branch)
    File.join(root_dir, key(repo_url, branch))
  end

  # Ready entries for a target, newest first.
  def ready_entries(repo_url, branch)
    dir = key_dir(repo_url, branch)
    return [] unless Dir.exist?(dir)

    Dir.children(dir)
       .reject { |name| name.start_with?(".") || AtomicCloneRemoval.tombstone?(name) }
       .sort_by { |name| -entry_epoch(name) }
       .map { |name| File.join(dir, name) }
  end

  # Move a ready clone onto `into` and bring it to the branch tip.
  #
  # @param into [String] the session's clone path; must not exist yet
  # @return [Boolean] true when `into` now holds a fresh clone; false when the
  #   pool had nothing usable and the caller should clone cold
  def claim(repo_url, branch, into:)
    return false unless enabled?

    FileUtils.mkdir_p(File.dirname(into))

    ready_entries(repo_url, branch).each do |entry|
      next if expired?(entry)

      begin
        File.rename(entry, into)
      rescue Errno::ENOENT, Errno::EEXIST, Errno::ENOTEMPTY
        # Another request claimed this one first, or a recycle removed it.
        next
      end

      # Age-based sweeps judge a clone by its mtime, and rename keeps the
      # entry's — up to MAX_AGE old. Restamp it so the clone dates from its
      # session, as a cold clone would.
      FileUtils.touch(into)

      begin
        catch_up!(into, branch)
      rescue GitCloneService::GitError => e
        logger.warn("Warm clone could not be brought to the branch tip; cloning cold", path: into, error: e.message)
        AtomicCloneRemoval.remove(into)
        return false
      end

      logger.info("Claimed a warm clone", repo_url: repo_url, branch: branch, path: into)
      return true
    end

    false
  rescue StandardError => e
    # The pool is an optimisation and must never be why a session fails. `into`
    # is a freshly generated path, so whatever is there came from this claim.
    logger.error("Warm clone claim failed; cloning cold", path: into, error: "#{e.class}: #{e.message}")
    AtomicCloneRemoval.remove(into) if File.exist?(into)
    false
  end

  # Bring the pool for every target up to `size`, recycle what has aged out, and
  # drop pools for repositories that are no longer a target. Idempotent: a run
  # with a full, fresh pool does nothing.
  #
  # @return [Hash] what the pass did, for the job's log line
  def replenish!
    result = { built: 0, recycled: 0, failed: nil }
    wanted = enabled? ? targets : []

    result[:recycled] += remove_untargeted!(wanted)

    wanted.each do |repo_url, branch|
      result[:recycled] += prune!(repo_url, branch)

      while ready_entries(repo_url, branch).size < size
        build!(repo_url, branch)
        result[:built] += 1
      end
    end

    result
  rescue GitCloneService::GitError, CloneDiskGuard::InsufficientDiskSpaceError => e
    logger.warn("Warm clone build failed; the next pass retries", error: e.message)
    result.merge(failed: e.message)
  end

  def build!(repo_url, branch)
    dir = key_dir(repo_url, branch)
    FileUtils.mkdir_p(dir)
    name = "#{Time.now.to_i}-#{SecureRandom.hex(4)}"
    building = File.join(dir, "#{BUILDING_PREFIX}#{name}")

    CloneDiskGuard.ensure_space!(repository_url: repo_url, base: ClonesDirectory.base)

    begin
      GitCloneService.run_git_command([ "clone", "--quiet", "--branch", branch, "--single-branch", repo_url, building ])
      File.rename(building, File.join(dir, name))
    rescue StandardError
      AtomicCloneRemoval.remove(building)
      raise
    end

    logger.info("Built a warm clone", repo_url: repo_url, branch: branch)
  end

  def catch_up!(path, branch)
    GitCloneService.run_git_command([ "fetch", "--quiet", "origin", branch ], cwd: path, timeout: FETCH_TIMEOUT_SECONDS)
    GitCloneService.run_git_command([ "reset", "--quiet", "--hard", "FETCH_HEAD" ], cwd: path, timeout: FETCH_TIMEOUT_SECONDS)
  end

  # Remove expired ready entries, abandoned builds, and the tombstones an
  # interrupted removal leaves (the hourly sweeps reap only the clones base
  # itself) for one target.
  def prune!(repo_url, branch)
    dir = key_dir(repo_url, branch)
    return 0 unless Dir.exist?(dir)

    Dir.children(dir).count do |name|
      path = File.join(dir, name)
      if AtomicCloneRemoval.tombstone?(name)
        FileUtils.rm_rf(path)
        next true
      end

      stale = if name.start_with?(BUILDING_PREFIX)
        age_seconds(path) > ABANDONED_BUILD_AGE
      elsif name.start_with?(".")
        false
      else
        expired?(path)
      end
      stale && AtomicCloneRemoval.remove(path)
    end
  end

  def remove_untargeted!(wanted)
    return 0 unless Dir.exist?(root_dir)

    keep = wanted.map { |repo_url, branch| key(repo_url, branch) }
    Dir.children(root_dir).reject { |name| keep.include?(name) || name.start_with?(".") }.count do |name|
      FileUtils.rm_rf(File.join(root_dir, name))
      true
    end
  end

  def expired?(path)
    age_seconds(path) > MAX_AGE
  end

  # Age from the epoch in the entry's name, which is when its clone started.
  def age_seconds(path)
    Time.now.to_i - entry_epoch(File.basename(path))
  end

  def entry_epoch(name)
    name.delete_prefix(BUILDING_PREFIX).split("-").first.to_i
  end

  def logger
    StructuredLogger.new({ service: "WarmClonePool" })
  end
end
