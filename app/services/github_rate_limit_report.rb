# frozen_string_literal: true

# What every human-facing surface says about GitHub's rate-limit budgets: /health, the
# trigger pages, `get_system_health`, `search_triggers`, and the stalled-polling page.
#
# GithubRateLimit owns the state: a breaker per credential and budget, and the
# once-a-minute snapshot GithubRateLimitSnapshotJob writes. This module only reads it, and it
# never calls GitHub. A surface reporting a spent budget must not spend more of it. The
# GitHub login comes from GithubTokenStatus's cache, so it is named when a probe already
# learned it and left out otherwise.
#
# A reading answers four questions a human asks of a spent budget:
#
#   - which budget, and whose: `core`, `graphql` or `search`, the variable holding the
#     token (a name, never a value) and its GitHub login when known;
#   - how much is left: remaining/limit;
#   - until when: the reset as an absolute UTC time and as "in N min";
#   - does trigger polling stop: the poller's sweep spends only `search`, so a spent
#     `core` or `graphql` budget leaves it running (GithubTriggerPollerJob polls through a
#     rate-limited preflight). A spent `search` budget pauses it until reset. When the
#     snapshot has no `search` reading for that credential, the answer is left unsaid.
#
# Like GithubRateLimit, it fails open: anything unreadable is reported as nothing known.
module GithubRateLimitReport
  # The budget GithubTriggerPollerJob's sweep spends.
  SWEEP_RESOURCE = "search"

  Reading = Data.define(:credential, :login, :resource, :remaining, :limit, :reset_at, :spent, :polling) do
    # `credential (login)`, or the variable name alone when the login is not known.
    def whose
      login ? "#{credential} (#{login})" : credential
    end

    def remaining_text
      return nil if remaining.nil?

      limit.to_i.positive? ? "#{remaining}/#{limit}" : remaining.to_s
    end

    # One sentence, e.g. "GH_TOKEN (tadasant)'s core budget is spent: 0/5000 left, resets
    # 2026-11-15 21:27 UTC (in 12 min). GitHub trigger polling continues through it: its sweep
    # spends only the search budget (28/30 left)."
    def message(now: Time.current)
      head = spent ? "spent" : "running low"
      text = "#{whose}'s #{resource} budget is #{head}"
      text += ": #{remaining_text} left" if remaining_text
      text += ", resets #{GithubRateLimitReport.reset_text(reset_at, now: now)}."
      note = polling_note
      note ? "#{text} #{note}" : text
    end

    def polling_note
      case polling
      when :paused
        "GitHub trigger polling is paused until then."
      when :paused_by_search
        "GitHub trigger polling is paused too, but by the spent search budget, not this one."
      when Hash
        "GitHub trigger polling continues through it: its sweep spends only the search budget " \
          "(#{polling[:search]})."
      end
    end

    def polling_continues?
      polling.is_a?(Hash)
    end

    def to_h(now: Time.current)
      {
        credential: credential, login: login, resource: resource,
        remaining: remaining, limit: limit, reset_at: reset_at.utc.iso8601, spent: spent,
        trigger_polling: case polling
                         when :paused, :paused_by_search then "paused"
                         when Hash then "continues"
                         end,
        message: message(now: now)
      }
    end
  end

  module_function

  # Every budget known to be spent, or running low (under GithubRateLimit::LOW_WATER, not
  # counting `search`, whose whole budget is 30 a minute), across every credential, spent
  # ones first. Empty when nothing is known to be wrong or nothing can be read.
  #
  # @return [Array<Reading>]
  def readings(env: ENV)
    collect(env)
  rescue => e
    Rails.logger.warn "[GithubRateLimitReport] Could not read GitHub rate-limit state (#{e.class}: #{e.message})"
    []
  end

  def spent(env: ENV)
    readings(env: env).select(&:spent)
  end

  # True when a spent `search` budget is holding the trigger poller's whole sweep right now:
  # every credential's search budget is spent. The sweep searches each owner with that
  # owner's token, so one token's spent budget leaves the others polling, and its own
  # reading already says so for that token alone.
  def sweep_blocked?(readings, env: ENV)
    blocked = readings.select { |reading| reading.spent && reading.resource == SWEEP_RESOURCE }.map(&:credential)
    return false if blocked.empty?

    GithubRateLimit.credentials(env: env).all? { |credential| blocked.include?(credential[:label]) }
  rescue => e
    Rails.logger.warn "[GithubRateLimitReport] Could not read GitHub credentials (#{e.class}: #{e.message})"
    false
  end

  # One paragraph for the stalled-polling page and its ERROR line, or nil when nothing is
  # known to be wrong. When this module cannot read the state, it falls back to
  # GithubRateLimit.diagnosis, so the page keeps whatever that can still say.
  def diagnosis(env: ENV, now: Time.current)
    found = collect(env)
    return nil if found.empty?

    "GitHub rate limit: #{found.map { |reading| reading.message(now: now) }.join(' ')} GitHub counts the " \
      "5000/hr REST budget per user across every token that user holds, so agent sessions running `gh` " \
      "as the same user spend it too."
  rescue => e
    Rails.logger.warn "[GithubRateLimitReport] Could not build a rate-limit diagnosis (#{e.class}: #{e.message}); " \
                      "falling back to GithubRateLimit.diagnosis"
    GithubRateLimit.diagnosis(env: env)
  end

  # "2026-11-15 21:27 UTC (in 12 min)"
  def reset_text(reset_at, now: Time.current)
    "#{reset_at.utc.strftime('%Y-%m-%d %H:%M UTC')} (#{relative(reset_at, now: now)})"
  end

  def relative(reset_at, now: Time.current)
    seconds = reset_at - now
    return "now" if seconds <= 0
    return "in under a minute" if seconds < 60

    "in #{(seconds / 60.0).ceil} min"
  end

  # --- internals ---------------------------------------------------------------

  # Every reading, spent ones first. Raises; .readings and .diagnosis decide what a failure means.
  def collect(env)
    found = GithubRateLimit.credentials(env: env).flat_map { |credential| credential_readings(credential, env) }
    found.sort_by { |reading| [ reading.spent ? 0 : 1, GithubRateLimit::RESOURCES.index(reading.resource) ] }
  end

  def credential_readings(credential, env)
    budgets = GithubRateLimit.snapshot(credential) || {}
    login = GithubTokenStatus.cached_login(env[credential[:label]])
    search = sweep_state(credential, budgets)

    GithubRateLimit::RESOURCES.filter_map do |resource|
      budget = budgets[resource]
      exhausted_until = GithubRateLimit.read_exhausted(credential, resource)
      snapshot_spent = budget && budget[:remaining].zero? && budget[:reset_at].future?

      if exhausted_until || snapshot_spent
        Reading.new(credential: credential[:label], login: login, resource: resource,
                    # A breaker means spent, whatever an older snapshot last counted.
                    remaining: 0, limit: budget&.dig(:limit),
                    reset_at: exhausted_until || budget[:reset_at], spent: true,
                    polling: if resource == SWEEP_RESOURCE then :paused
                             elsif search == :paused then :paused_by_search
                             else search
                             end)
      elsif budget && resource != SWEEP_RESOURCE && budget[:remaining] < GithubRateLimit::LOW_WATER &&
            budget[:reset_at].future?
        Reading.new(credential: credential[:label], login: login, resource: resource,
                    remaining: budget[:remaining], limit: budget[:limit], reset_at: budget[:reset_at],
                    spent: false, polling: nil)
      end
    end
  end

  # How the credential's `search` budget stands, as the polling answer for its other
  # spent budgets: :paused when it is spent too (reported on them as :paused_by_search), { search: "28/30 left" } when the snapshot
  # shows some left, nil when nothing says.
  def sweep_state(credential, budgets)
    search = budgets[SWEEP_RESOURCE]
    return :paused if GithubRateLimit.read_exhausted(credential, SWEEP_RESOURCE)
    return nil unless search
    # The search window is a minute long. A reading whose reset has passed says the budget
    # has refilled since, which is still an answer.
    return { search: "refilled since the last reading" } unless search[:reset_at].future?
    return :paused if search[:remaining].zero?

    left = search[:limit].to_i.positive? ? "#{search[:remaining]}/#{search[:limit]}" : search[:remaining].to_s
    { search: "#{left} left" }
  end
end
