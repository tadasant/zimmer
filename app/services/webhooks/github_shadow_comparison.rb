# frozen_string_literal: true

module Webhooks
  # Lines up what GitHub's webhook would have fired against what the poller did fire, while
  # `GITHUB_TRIGGER_INGEST_MODE=webhook_shadow` (Webhooks::Source). It is the evidence for moving
  # GitHub to `webhook_with_poll_fallback`: in shadow the poller still fires everything, so a
  # webhook that agrees with it on every event, ahead of it, is a webhook that can take over.
  #
  # Reads TriggerShadowObservation, which both paths write in shadow mode, and pairs one condition's
  # observations of one event key: the i-th webhook observation with the i-th poll observation, in
  # time order, so a label that comes off and goes back on is two events, not one. Each event is
  #
  #   matched       both paths saw it. Latency is the poll's time minus the webhook's: positive
  #                 when the webhook was ahead, which it should be by about a poll interval.
  #   webhook_only  the webhook would have fired it and the poller never did. In
  #                 `webhook_with_poll_fallback` that would be a session the poller never spawns —
  #                 the matching rules in GithubEventJob disagree with the poller's.
  #   poll_only     the poller fired it and no delivery would have: a delivery GitHub dropped, a
  #                 hook missing an event, or a delivery that arrived after the poller had fired.
  #   pending       one path has seen it, and it is younger than the grace, so the other may yet.
  #
  # An event counts in the window if its FIRST observation is inside it. Observations from up to one
  # grace before the window are read too, so an event that straddles the window's start pairs.
  #
  # Shown on /health and carried by `GET /api/v1/health` and `get_system_health` through
  # Webhooks::IngestSummary; `compare_github_webhook_shadow` takes its own window.
  class GithubShadowComparison
    WINDOW = 24.hours
    MAX_GRACE = 24.hours
    DEFAULT_RECENT = 30
    MAX_RECENT = 200

    STATUSES = %w[matched webhook_only poll_only pending].freeze

    # How long one path's observation may wait for the other's before it counts as a miss: the
    # liveness threshold, which is two poll intervals plus slack. 15 minutes at the default.
    def self.default_grace
      GithubTriggerPollCadence.current.liveness_threshold
    end

    def self.report(**options)
      new(**options).report
    end

    # +condition_id+ narrows to one condition. +conditions+ is the scope the caller may see, for a
    # restricted MCP connection; everything when nil. +recent_unmatched+ lists only events that are
    # not `matched` in `recent`, for a card that has room only for the ones worth reading.
    def initialize(now: Time.current, since: nil, grace: nil, condition_id: nil, conditions: nil, recent: DEFAULT_RECENT,
                   recent_unmatched: false)
      @now = now
      @since = since || (now - WINDOW)
      @grace = (grace || self.class.default_grace).clamp(0, MAX_GRACE)
      @condition_id = condition_id
      @conditions = conditions
      @recent = recent.to_i.clamp(0, MAX_RECENT)
      @recent_unmatched = recent_unmatched
    end

    def report
      events = classified_events
      by_condition = events.group_by { |event| event[:condition_id] }

      {
        mode: Source.github.mode,
        since: @since,
        window_seconds: (@now - @since).round,
        grace_seconds: @grace.to_i,
        poll_interval_seconds: GithubTriggerPollCadence.current.interval.to_i,
        totals: counts(events),
        latency: latency(events),
        conditions: condition_rows(by_condition),
        recent: recent(events)
      }
    end

    private

    def recent(events)
      listed = @recent_unmatched ? events.reject { |event| event[:status] == "matched" } : events
      listed.sort_by { |event| event[:first_at] }.last(@recent).reverse.map { |event| present(event) }
    end

    def observations
      scope = TriggerShadowObservation.where(created_at: (@since - @grace)..@now)
      scope = scope.where(trigger_condition_id: @condition_id) if @condition_id
      scope = scope.where(trigger_condition_id: @conditions.select(:id)) if @conditions
      scope.order(:created_at).pluck(:trigger_condition_id, :event_key, :path, :created_at)
    end

    def classified_events
      horizon = @now - @grace

      observations.group_by { |condition_id, key, _path, _at| [ condition_id, key ] }.flat_map do |(condition_id, key), rows|
        webhook = rows.select { |row| row[2] == "webhook" }.map(&:last)
        poll = rows.select { |row| row[2] == "poll" }.map(&:last)

        Array.new([ webhook.size, poll.size ].max) do |i|
          webhook_at = webhook[i]
          poll_at = poll[i]
          first_at = [ webhook_at, poll_at ].compact.min
          status = if webhook_at && poll_at then "matched"
          elsif first_at > horizon then "pending"
          elsif webhook_at then "webhook_only"
          else "poll_only"
          end

          { condition_id: condition_id, event: key, status: status, first_at: first_at, webhook_at: webhook_at, poll_at: poll_at }
        end
      end.select { |event| event[:first_at] >= @since }
    end

    def counts(events)
      tally = events.map { |event| event[:status] }.tally
      STATUSES.to_h { |status| [ status.to_sym, tally.fetch(status, 0) ] }
    end

    # Seconds the webhook was ahead of the poller on matched events. Negative is the poller ahead.
    def latency(events)
      samples = events.filter_map { |event| (event[:poll_at] - event[:webhook_at]).round if event[:status] == "matched" }.sort
      return { samples: 0, median_seconds: nil, p90_seconds: nil, max_seconds: nil } if samples.empty?

      {
        samples: samples.size,
        median_seconds: percentile(samples, 0.5),
        p90_seconds: percentile(samples, 0.9),
        max_seconds: samples.last
      }
    end

    # Nearest-rank, so the answer is always an observed value.
    def percentile(sorted, fraction)
      sorted[((sorted.size * fraction).ceil - 1).clamp(0, sorted.size - 1)]
    end

    def condition_rows(by_condition)
      conditions = TriggerCondition.where(id: by_condition.keys).includes(:trigger).index_by(&:id)

      by_condition.sort_by { |condition_id, _| condition_id }.map do |condition_id, events|
        condition = conditions[condition_id]
        {
          condition_id: condition_id,
          condition_type: condition&.condition_type,
          trigger_id: condition&.trigger_id,
          trigger_name: condition&.trigger&.name,
          counts: counts(events),
          latency: latency(events)
        }
      end
    end

    def present(event)
      {
        condition_id: event[:condition_id],
        event: event[:event],
        status: event[:status],
        webhook_at: event[:webhook_at]&.iso8601,
        poll_at: event[:poll_at]&.iso8601,
        webhook_lead_seconds: event[:webhook_at] && event[:poll_at] ? (event[:poll_at] - event[:webhook_at]).round : nil
      }
    end
  end
end
