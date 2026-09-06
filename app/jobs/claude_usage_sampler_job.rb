# frozen_string_literal: true

# Takes a scheduled quota reading of the accounts the spot gate decides on, so
# the number it decides on is fresh — the serving account every tick, and any
# spare whose reading has gone stale.
#
# == Why this job has to exist
#
# QuotaResetCheckerJob already runs every 15 minutes and already writes snapshots
# — but only for accounts in `quota_exceeded`, because its job is to notice when
# one recovers. A healthy account otherwise gets a reading only when somebody
# opens /inference or a rotation happens, which can be days apart.
#
# == Why spares are sampled too
#
# The gate decides on `ClaudeAccountPool`, which averages the latest reading of
# EVERY account in the pool. A spare's reading is therefore one of N terms in the
# number that holds or releases the whole spot fleet, and a stale one is wrong in
# both directions: a spare last read at 90% whose windows have since drained
# holds work that should be running, and one last read at 5% before a burst of
# priority work spent it releases work onto headroom that is not there (#501).
#
# == The cadence: stale-first, serving always
#
# Each tick samples the serving account unconditionally — it is the one spend is
# accruing against, so it is the one moving fastest, and nothing here may make it
# less fresh. Then it works down the other accounts whose newest snapshot is
# older than `SPARE_MAX_STALENESS`, oldest reading first and never-sampled ahead
# of everything, until `MAX_SPARE_PROBES_PER_TICK` readings have landed or
# `MAX_SPARE_ATTEMPTS_PER_TICK` probes have been spent.
#
# Sampling on STALENESS rather than on a fixed rotation is what keeps the probe
# count off the pool size and lets every other writer count. A `quota_exceeded`
# account is already re-read by QuotaResetCheckerJob every 15 minutes and an
# account somebody just looked at on /inference was written by that page view, so
# neither is ever stale enough to be picked here. The job spends probes only on
# accounts nothing else is reading.
#
# == The two budgets, and why a failure needs its own
#
# A probe that fails writes no snapshot, so the account it failed on stays
# exactly as stale as it was — which puts it back at the head of the stale-first
# ordering on the very next tick, and every tick after that. On a success budget
# alone, two accounts Anthropic refuses would take both slots forever and the
# spares that CAN be read would never be reached again: the #501 bug restored,
# for the accounts that still work.
#
# The attempt budget is what stops that. A failure spends an attempt and the
# sweep moves down to the next candidate in the same tick, so a tick still lands
# MAX_SPARE_PROBES_PER_TICK readings as long as fewer than
# `MAX_SPARE_ATTEMPTS_PER_TICK - MAX_SPARE_PROBES_PER_TICK` accounts are refusing.
#
# == Cost
#
# One `QuotaCheckService` probe per attempt: a profile GET plus a 1-token message
# POST, purely to read the rate-limit response headers.
#
#   Serving account:      96 probes/day.
#   A spare that answers: at most 24/day — a landed reading is fresh for
#                         SPARE_MAX_STALENESS, so the account cannot be picked
#                         again for 5 ticks.
#   A spare that refuses:  up to 96/day. It writes no reading, so it stays
#                         eligible; retrying it is what the attempt budget bounds
#                         rather than prevents, because an account whose token
#                         starts working again has no other way back into the
#                         average.
#   Pool of N:            96 + 24(N-1) probes/day while every probe answers, and
#                         never more than 1 + MAX_SPARE_ATTEMPTS_PER_TICK = 5 in
#                         one tick (480/day) whatever is failing.
#
# That is the middle of the three shapes #501 named: probing every account every
# tick would be 96N/day, and round-robining one spare per tick would leave a
# spare's staleness growing with the pool.
#
# == The staleness bound
#
# A spare's reading is at most SPARE_MAX_STALENESS + one tick old — 75 minutes at
# the 15-minute cadence in config/cron_schedule.rb — as long as the spares going
# stale in a tick fit under the per-tick budget. An account probed at tick T is
# not stale at T+60 and is picked at T+75, so the steady-state period is 5 ticks
# and the budget covers 5 * MAX_SPARE_PROBES_PER_TICK = 10 spares. A pool larger
# than that degrades toward the round-robin shape — staleness grows with the pool
# — rather than bursting probes, which is what the budgets are for. So does the
# tick after a gap (a deploy, a queue backlog, several accounts added at once),
# where every spare is stale at once and the sweep drains them a budget at a time.
#
# An account in `needs_reauth`, or one whose token is expired with no refresh
# token, is skipped without a probe: Zimmer cannot authenticate it, so a probe
# would fail every time — and because it can never become fresh, letting it into
# the stale-first ordering would spend an attempt every tick for nothing.
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

  # How many spare readings one tick aims to land, so a pool that grows — or that
  # all goes stale at once after a gap — spreads its probes over ticks instead of
  # firing them in one.
  MAX_SPARE_PROBES_PER_TICK = Integer(ENV.fetch("CLAUDE_SPARE_SAMPLE_MAX_PROBES_PER_TICK", "2"))

  # How many probes one tick may spend reaching that many readings. The slack
  # over MAX_SPARE_PROBES_PER_TICK is how many refusing accounts a tick can walk
  # past before it gives up — see "The two budgets" above.
  MAX_SPARE_ATTEMPTS_PER_TICK = MAX_SPARE_PROBES_PER_TICK * 2

  def perform
    serving = serving_account
    if serving
      sample(serving)
    else
      Rails.logger.debug("[ClaudeUsageSamplerJob] No serving Claude Code account — nothing to sample")
    end

    sample_spares(excluding: serving)
  rescue StandardError => e
    Rails.logger.warn("[ClaudeUsageSamplerJob] Sampling failed: #{e.class}: #{e.message}")
    nil
  end

  private

  # Work down the stale candidates until this tick's budgets are spent.
  def sample_spares(excluding:)
    landed = 0
    attempts = 0

    stale_spares(excluding: excluding).each do |account|
      break if landed >= MAX_SPARE_PROBES_PER_TICK || attempts >= MAX_SPARE_ATTEMPTS_PER_TICK

      attempts += 1
      landed += 1 if sample(account)
    end
  end

  # Probe one account and store the reading. Returns whether a snapshot landed,
  # which is what spends this tick's success budget.
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

  # Every candidate in the gate's pool other than the one just sampled, stalest
  # first — the whole ordering, not this tick's slice, because how far down it a
  # tick gets depends on which probes answer.
  #
  # The pool is `ClaudeAccountPool`'s pool, deliberately: an account is worth a
  # probe here exactly when its reading is a term in the average the gate decides
  # on, whatever its status.
  #
  # Ties break on id, so which of two equally stale accounts goes first is
  # reproducible rather than left to Postgres heap order.
  def stale_spares(excluding:)
    accounts = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).to_a
    accounts.reject! { |account| account.id == excluding&.id }
    accounts.select! { |account| probeable?(account) }
    return [] if accounts.empty?

    snapshots = ClaudeAccountPool.latest_snapshots(accounts)
    cutoff = SPARE_MAX_STALENESS.ago
    never_read = Time.zone.at(0)

    accounts
      .map { |account| [ account, snapshots[account.id]&.created_at ] }
      .select { |_account, read_at| read_at.nil? || read_at < cutoff }
      .sort_by { |account, read_at| [ read_at || never_read, account.id ] }
      .map(&:first)
  end

  # Whether a probe of this account could possibly succeed, decided from the DB
  # alone. False for an account Zimmer has no way to authenticate — probing it
  # would fail every tick, so it would spend an attempt every tick for a reading
  # that can never land.
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
