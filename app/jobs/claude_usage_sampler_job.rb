# frozen_string_literal: true

# Takes a scheduled quota reading of the accounts the spot gate decides on, so
# the number it decides on is fresh — the serving account every tick, and any
# spare whose reading has gone stale.
#
# == Why this job has to exist
#
# QuotaResetCheckerJob already runs every 15 minutes and already writes snapshots
# — but only for accounts in `quota_exceeded`, because its job is to notice when
# one recovers. A healthy account only got a reading when somebody opened /inference
# or a rotation happened, which can be days apart.
#
# == Why spares are sampled too
#
# The gate decides on `ClaudeAccountPool`, which averages the latest reading of
# EVERY account in the pool. A spare's reading is therefore one of N terms in the
# number that holds or releases the whole spot fleet, and it was wrong in both
# directions when it went stale: a spare last read at 90% whose windows have
# since drained holds work that should be running, and one last read at 5% before
# a burst of priority work spent it releases work onto headroom that is not there
# (#501).
#
# == The cadence: stale-first, serving always
#
# Each tick samples the serving account unconditionally — it is the one spend is
# accruing against, so it is the one moving fastest, and nothing here may make it
# less fresh than it already was. Then it samples up to
# `MAX_SPARE_PROBES_PER_TICK` other accounts whose newest snapshot is older than
# `SPARE_MAX_STALENESS`, oldest reading first, never-sampled ahead of everything.
#
# Sampling on STALENESS rather than on a fixed rotation is what keeps the probe
# count off the pool size and lets every other writer count. A `quota_exceeded`
# account is already re-read by QuotaResetCheckerJob every 15 minutes and an
# account somebody just looked at on /inference was written by that page view, so
# neither is ever stale enough to be picked here. The job spends probes only on
# accounts nothing else is reading.
#
# == Cost
#
# One `QuotaCheckService` probe per account sampled: a profile GET plus a 1-token
# message POST, purely to read the rate-limit response headers.
#
#   Serving account: 96 probes/day, unchanged.
#   Each spare:      at most 24/day — once probed it is fresh for
#                    SPARE_MAX_STALENESS (4 ticks), so it cannot be picked again
#                    before then.
#   Pool of N:       at most 96 + 24(N-1) probes/day, and at most 1 + 2 = 3 in
#                    any one tick. N=2 → 120/day, N=3 → 144/day, N=5 → 192/day.
#
# That is the middle of the three shapes #501 named: probing every account every
# tick would be 96N/day, and round-robining one spare per tick would leave a
# spare's staleness growing with the pool.
#
# == The staleness bound
#
# A spare's reading is at most SPARE_MAX_STALENESS + one tick old — 75 minutes at
# the defaults — as long as the stale spares in a tick fit under the per-tick cap.
# They do for any pool up to 1 + (SPARE_MAX_STALENESS / tick) * cap = 9 accounts
# at the defaults; a larger pool degrades to the round-robin shape rather than
# bursting probes, which is what the cap is for.
#
# An account in `needs_reauth`, or one whose token is expired with no refresh
# token, is skipped without a probe: Zimmer cannot authenticate it, so a probe
# would fail every time — and because it can never become fresh, letting it into
# the stale-first ordering would starve the spares that CAN be read.
#
# Failures are swallowed, per account. A missing sample leaves the gate deciding
# on a slightly older reading; it must never take down the scheduler, mark an
# account on a network blip, or stop the other accounts being sampled — only
# QuotaSnapshotService decides what a reading means for account status, and it
# does so identically no matter which caller supplied the reading.
class ClaudeUsageSamplerJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  # How old a spare's reading may get before this job spends a probe on it.
  SPARE_MAX_STALENESS = Integer(ENV.fetch("CLAUDE_SPARE_SAMPLE_MAX_STALENESS_MINUTES", "60")).minutes

  # How many spares one tick may probe, so a pool that grows — or that all goes
  # stale at once after an outage — spreads its probes over ticks instead of
  # firing them in one.
  MAX_SPARE_PROBES_PER_TICK = Integer(ENV.fetch("CLAUDE_SPARE_SAMPLE_MAX_PROBES_PER_TICK", "2"))

  def perform
    serving = serving_account
    if serving
      sample(serving)
    else
      Rails.logger.debug("[ClaudeUsageSamplerJob] No serving Claude Code account — nothing to sample")
    end

    stale_spares(excluding: serving).each { |account| sample(account) }
  rescue StandardError => e
    Rails.logger.warn("[ClaudeUsageSamplerJob] Sampling failed: #{e.class}: #{e.message}")
    nil
  end

  private

  # Probe one account and store the reading. Returns whether a snapshot landed.
  #
  # Every failure mode stops at this method: one account with a dead token, a
  # refused probe or a raising HTTP client must not cost the pool the readings of
  # the accounts sampled after it.
  def sample(account)
    token = access_token_for(account)
    unless token
      Rails.logger.info("[ClaudeUsageSamplerJob] No usable token for #{account.email} — skipping sample")
      return false
    end

    result = QuotaCheckService.check_with_token(token)
    unless result.success?
      Rails.logger.info("[ClaudeUsageSamplerJob] Quota probe failed for #{account.email}: #{result.error_message}")
      return false
    end

    QuotaSnapshotService.save_snapshot(account, result, trigger: "usage_sample")
    true
  rescue StandardError => e
    Rails.logger.warn("[ClaudeUsageSamplerJob] Sampling #{account.email} failed: #{e.class}: #{e.message}")
    false
  end

  # The account spend accrues against: the current one, falling back to the
  # highest-priority available account when nothing is flagged current.
  def serving_account
    scope = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME)
    scope.find_by(is_current: true, status: :active) || scope.available.first
  end

  # The accounts in the gate's pool, other than the one just sampled, whose
  # newest reading has aged past SPARE_MAX_STALENESS — stalest first, capped.
  #
  # The pool is `ClaudeAccountPool`'s pool, deliberately: an account is worth a
  # probe here exactly when its reading is a term in the average the gate decides
  # on, whatever its status.
  def stale_spares(excluding:)
    accounts = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).to_a
    accounts.reject! { |account| account.id == excluding&.id }
    accounts.select! { |account| probeable?(account) }
    return [] if accounts.empty?

    snapshots = ClaudeAccountPool.latest_snapshots(accounts)
    cutoff = SPARE_MAX_STALENESS.ago

    accounts
      .map { |account| [ account, snapshots[account.id]&.created_at ] }
      .select { |_account, read_at| read_at.nil? || read_at < cutoff }
      .sort_by { |_account, read_at| read_at || Time.zone.at(0) }
      .first(MAX_SPARE_PROBES_PER_TICK)
      .map(&:first)
  end

  # Whether a probe of this account could possibly succeed, decided from the DB
  # alone. False for an account Zimmer has no way to authenticate as — probing it
  # would fail every tick, and it would sit at the head of the stale-first
  # ordering forever while doing so.
  def probeable?(account)
    return false if account.needs_reauth?
    return true if account.can_refresh_token?

    account.claude_access_token.present? && !account.token_expired?
  end

  def access_token_for(account)
    if (account.token_expired? || account.token_expiring_soon?) && account.can_refresh_token?
      return nil unless account.refresh_token!

      account.reload
    end
    return nil if account.token_expired?

    account.claude_access_token
  end
end
