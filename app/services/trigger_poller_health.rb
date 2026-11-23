# frozen_string_literal: true

# The trigger pollers' liveness as /health, `GET /api/v1/health` and `get_system_health`
# show it: for each poller with something to poll, when it last polled, and whether that
# is polling, stalled, or paused by a spent GitHub rate limit. Spent and low GitHub
# budgets come with it (GithubRateLimitReport), so "GitHub polling stalled" and "GitHub
# polling paused until 21:27 UTC by a spent search budget" read as the different things
# they are.
#
# It reads what TriggerPollerLivenessCheckJob reads: the same POLLERS, the same heartbeats,
# the same thresholds. It never pages. Paging stays with that job, and it pages on a stale
# heartbeat whatever this says. It calls no external API: `watched` is a database query, and
# `seedable` (which, for GitHub, runs `gh auth status`) is never consulted.
module TriggerPollerHealth
  NAMES = {
    github: "GitHub", slack: "Slack", mcp_event: "MCP event"
  }.freeze

  module_function

  # @return [Hash] { pollers: [...], github_rate_limit: [...], status: HealthMonitorService::HealthStatus }
  def report(now: Time.current)
    rate_limit = GithubRateLimitReport.readings
    sweep_blocked = GithubRateLimitReport.sweep_blocked?(rate_limit)

    pollers = TriggerPollerLivenessCheckJob::POLLERS.filter_map do |poller|
      next unless poller.watched.call

      describe(poller, now: now, sweep_blocked: poller.key == :github && sweep_blocked, rate_limit: rate_limit)
    end

    {
      pollers: pollers,
      github_rate_limit: rate_limit.map { |reading| reading.to_h(now: now) },
      status: status(pollers, rate_limit)
    }
  end

  def describe(poller, now:, sweep_blocked:, rate_limit:)
    last_at = PollerHeartbeat.last_at(poller.key)
    # A duration, or a lambda for one that follows a setting (GitHub's poll cadence), resolved
    # the way TriggerPollerLivenessCheckJob#threshold_for resolves it.
    threshold = poller.threshold.respond_to?(:call) ? poller.threshold.call : poller.threshold
    age = last_at && (now - last_at)
    name = NAMES.fetch(poller.key, poller.key.to_s.humanize)
    since = last_at ? "last poll #{HealthMonitorService.format_wait(age)} ago" : "no poll recorded on this host yet"

    # A stale heartbeat is a stall whatever else is true: the search window is a minute long,
    # so a budget spent right now cannot account for a quarter of an hour without a poll.
    # Under the threshold, a sweep that every token's spent search budget is holding reads
    # as paused, with the time it ends.
    state, message =
      if last_at && age >= threshold
        [ "stalled",
          "#{name} trigger polling stalled: no successful poll in ~#{(age / 60).round} min " \
            "(pages past #{(threshold / 60).round} min). #{stall_cause(poller, rate_limit)}".strip ]
      elsif sweep_blocked
        search = rate_limit.find { |reading| reading.spent && reading.resource == GithubRateLimitReport::SWEEP_RESOURCE }
        [ "rate_limited",
          "#{name} trigger polling is paused: #{search.whose}'s GitHub search budget is spent until " \
            "#{GithubRateLimitReport.reset_text(search.reset_at, now: now)}; #{since}." ]
      elsif last_at.nil?
        [ "no_heartbeat", "#{name} trigger polling has no poll recorded on this host yet." ]
      else
        [ "polling", "#{name} trigger polling is running: #{since}." ]
      end

    {
      key: poller.key.to_s, name: name, state: state, message: message,
      last_poll_at: last_at&.utc&.iso8601, age_seconds: age&.round,
      threshold_seconds: threshold.to_i
    }
  end

  # For a stalled GitHub poller, what the spent budgets do and do not explain. The sweep
  # spends only `search`, so a spent core or graphql budget is never the cause, and saying so
  # keeps a responder from waiting for a reset that will not help. A spent search budget is
  # named alongside, but a one-minute window cannot account for the stall on its own.
  def stall_cause(poller, rate_limit)
    return "" unless poller.key == :github

    spent = rate_limit.select(&:spent)
    elsewhere = "look at the worker (/jobs), a hung `gh`, or GitHub itself."
    return "No GitHub budget is known to be spent, so #{elsewhere}" if spent.empty?

    search, others = spent.partition { |reading| reading.resource == GithubRateLimitReport::SWEEP_RESOURCE }
    notes = []
    if others.any?
      notes << "A spent #{others.map(&:resource).uniq.join('/')} budget does not stop the sweep, which spends only search."
    end
    if search.any?
      notes << "The search budget is spent right now, but its window is a minute long, so it does not explain the stall alone."
    end
    "#{notes.join(' ')} #{search.any? ? 'Also' : 'So'} #{elsewhere}"
  end

  def status(pollers, rate_limit)
    stalled = pollers.select { |poller| poller[:state] == "stalled" }
    limited = pollers.select { |poller| poller[:state] == "rate_limited" }
    spent = rate_limit.select(&:spent)

    if stalled.any?
      HealthMonitorService::HealthStatus.new(status: :critical, message: stalled.map { |poller| poller[:message] }.join(" "))
    elsif limited.any?
      HealthMonitorService::HealthStatus.new(status: :warning, message: limited.map { |poller| poller[:message] }.join(" "))
    elsif spent.any?
      HealthMonitorService::HealthStatus.new(status: :warning, message: "GitHub rate limit: #{spent.map(&:message).join(' ')}")
    elsif pollers.empty?
      HealthMonitorService::HealthStatus.new(status: :healthy, message: "No trigger poller has anything to poll.")
    else
      HealthMonitorService::HealthStatus.new(
        status: :healthy,
        message: "#{pollers.size} trigger #{'poller'.pluralize(pollers.size)} polling within #{pollers.size == 1 ? 'its' : 'their'} thresholds."
      )
    end
  end
end
