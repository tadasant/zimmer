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
# caller makes an ordinary clone instead.
#
# == Replenishment
#
# WarmClonePoolReplenishJob refills the pool: enqueued on every claim, and on a
# one-minute cron as the backstop that converges after a deploy, a failed build
# or a race. A clone is replaced once it passes RECYCLE_AGE, and the replacement
# is built before the old one is removed; claims accept a clone up to MAX_AGE, so
# the gap between the two keeps the pool from going empty on the hour. Keeping
# clones young also keeps the claim's fetch a few commits deep.
module WarmClonePool
  DIRNAME = ".warm-clones"
  BUILDING_PREFIX = ".building-"

  # The oldest clone a claim accepts.
  MAX_AGE = 1.hour

  # When the refill replaces a clone. Well inside MAX_AGE, so the replacement is
  # ready before the old one stops being claimable.
  RECYCLE_AGE = 45.minutes

  # A build that has not finished in this long died with its worker.
  ABANDONED_BUILD_AGE = 30.minutes

  # Per git command (fetch, then reset) in the claim's catch-up, which runs on
  # the request's critical path. A fetch that takes longer than this is a sign
  # GitHub is struggling, and an ordinary clone is no worse a bet.
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
      rescue GitCloneService::GitError, IncompleteCloneError => e
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
      # Build first, prune second: a clone past RECYCLE_AGE stays claimable until
      # its replacement exists.
      size.times do
        break if fresh_entries(repo_url, branch).size >= size

        unless room_to_build?(repo_url)
          result[:failed] = "not enough free disk to keep a warm clone beside the sessions' own"
          break
        end

        build!(repo_url, branch)
        result[:built] += 1
      end

      result[:recycled] += prune!(repo_url, branch)
    end

    result
  rescue GitCloneService::GitError => e
    logger.warn("Warm clone build failed; the next pass retries", error: e.message)
    result.merge(failed: e.message)
  end

  # Ready entries young enough not to need replacing yet.
  def fresh_entries(repo_url, branch)
    ready_entries(repo_url, branch).reject { |entry| age_seconds(entry) > RECYCLE_AGE }
  end

  # Whether the volume can take a pooled clone and still have what an ordinary
  # clone of the same repository would need. Never reclaims: the pool is
  # invisible to orphan reclamation, so a build that made room by pruning would
  # be spending space the sessions' own clones are counting on. An unmeasurable
  # volume fails open, as CloneDiskGuard does.
  def room_to_build?(repo_url)
    stats = CloneDiskGuard.volume_stats(ClonesDirectory.base)
    return true if stats.nil?
    return true if stats[:available] >= CloneDiskGuard::MAXIMUM_REQUIRED_BYTES * 2

    stats[:available] >= CloneDiskGuard.required_bytes(repo_url, base: ClonesDirectory.base, total: stats[:total]) * 2
  end

  def build!(repo_url, branch)
    dir = key_dir(repo_url, branch)
    FileUtils.mkdir_p(dir)
    name = "#{Time.now.to_i}-#{SecureRandom.hex(4)}"
    building = File.join(dir, "#{BUILDING_PREFIX}#{name}")

    begin
      GitCloneService.run_git_command([ "clone", "--quiet", "--branch", branch, "--single-branch", repo_url, building ])
      File.rename(building, File.join(dir, name))
    rescue StandardError
      AtomicCloneRemoval.remove(building)
      raise
    end

    logger.info("Built a warm clone", repo_url: repo_url, branch: branch)
  end

  # Raised when a claimed directory is not a git work tree of its own. Run in a
  # directory without `.git`, git would walk up to an enclosing repository and
  # fetch and reset that one instead.
  class IncompleteCloneError < StandardError; end

  def catch_up!(path, branch)
    raise IncompleteCloneError, "#{path} has no .git directory" unless File.directory?(File.join(path, ".git"))

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
        replaceable?(path, repo_url, branch)
      end
      stale && AtomicCloneRemoval.remove(path)
    end
  end

  def remove_untargeted!(wanted)
    return 0 unless Dir.exist?(root_dir)

    keep = wanted.map { |repo_url, branch| key(repo_url, branch) }
    Dir.children(root_dir).reject { |name| keep.include?(name) || name.start_with?(".") }.count do |name|
      path = File.join(root_dir, name)
      # Atomic, because a worker that still counts this repository as a target
      # may be listing it to claim from; it must find the directory whole or gone.
      AtomicCloneRemoval.tombstone?(name) ? FileUtils.rm_rf(path) : AtomicCloneRemoval.remove(path)
      true
    end
  end

  # A clone past RECYCLE_AGE goes once a fresh one stands in for it, and past
  # MAX_AGE it goes regardless, since no claim will take it.
  def replaceable?(path, repo_url, branch)
    return true if expired?(path)

    age_seconds(path) > RECYCLE_AGE && fresh_entries(repo_url, branch).size >= size
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
