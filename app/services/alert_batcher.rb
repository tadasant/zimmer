# frozen_string_literal: true

# Collects alerts raised during a block and collapses bursts that share the
# same (title, source) pair into one aggregated Slack message.
#
# Motivation:
#   A single trigger-scheduler tick iterates many triggers and calls
#   Trigger#heal_stale_* on each. When a common dependency (e.g., an MCP
#   server) disappears from the catalog, every affected trigger fires its
#   own AlertService.raise_alert call. Per-trigger dedup keys don't dedup
#   across triggers, so #eng-alerts gets N separate messages for one event.
#
#   AlertBatcher solves this by grouping within-batch alerts by (title,
#   source) and emitting a single consolidated message when the batch
#   closes.
#
# Usage:
#   AlertBatcher.with_batch do
#     # ... code that may call AlertService.raise_alert many times ...
#   end
#
# Nesting is safe: inner `with_batch` calls reuse the outer batch's state,
# so only the outermost block flushes. This lets jobs wrap their perform
# method without worrying about inner service calls that also batch.
class AlertBatcher
  # Slack's section text limit is 3000 chars. Leave headroom for the
  # "N occurrences" header and separators.
  MAX_AGGREGATED_DETAILS_CHARS = 2700

  class << self
    def open?
      !Thread.current[:alert_batch].nil?
    end

    # Collect alerts raised inside the block and flush them on exit.
    # @yield the block during which alerts are collected
    # @return the block's return value
    def with_batch
      if open?
        yield
      else
        Thread.current[:alert_batch] = Hash.new { |h, k| h[k] = [] }
        begin
          yield
        ensure
          begin
            flush!
          ensure
            Thread.current[:alert_batch] = nil
          end
        end
      end
    end

    # Record an event in the current batch. Called by AlertService.raise_alert
    # when a batch is open.
    # @return [Boolean] true (the alert is considered "accepted"; actual emit
    #   happens on flush)
    def record(title, details:, source:, dedup_key:)
      Thread.current[:alert_batch][[ title, source ]] << {
        details: details,
        dedup_key: dedup_key
      }
      true
    end

    private

    def flush!
      batch = Thread.current[:alert_batch]
      return if batch.blank?

      # Per-group rescue: a Slack API failure on one group must not prevent
      # subsequent groups from emitting. Without this, the `batch.each` loop
      # would bail on the first raise and silently drop remaining groups.
      batch.each do |(title, source), events|
        begin
          if events.size == 1
            e = events.first
            AlertService.emit(
              title,
              details: e[:details],
              source: source,
              dedup_key: e[:dedup_key]
            )
          else
            AlertService.emit(
              "#{title} (×#{events.size})",
              details: aggregate_details(events),
              source: source,
              dedup_key: aggregate_dedup_key(title, source, events)
            )
          end
        rescue => e
          Rails.logger.error(
            "[AlertBatcher#flush!] Failed to emit aggregated alert " \
            "(title=#{title.inspect}, source=#{source.inspect}, events=#{events.size}): " \
            "#{e.class}: #{e.message}"
          )
        end
      end
    end

    def aggregate_details(events)
      header = "*#{events.size} occurrences in this run* — grouped to reduce alert spam.\n\n"
      body = events.each_with_index.map { |e, i| "*—— #{i + 1} ——*\n#{e[:details]}" }.join("\n\n")
      out = header + body
      out.length > MAX_AGGREGATED_DETAILS_CHARS ? out.truncate(MAX_AGGREGATED_DETAILS_CHARS) : out
    end

    # Dedup the aggregated message by the set of per-event dedup keys, so that
    # the same burst signature (same triggers affected) is suppressed inside
    # the AlertService dedup window. A different set of affected triggers
    # produces a different digest and will emit again.
    def aggregate_dedup_key(title, source, events)
      # Use the full SHA256 digest (not a 16-char prefix) so two genuinely
      # different bursts can't silently collide and suppress each other.
      digest = Digest::SHA256.hexdigest(events.map { |e| e[:dedup_key] }.sort.join("|"))
      "batch:#{source}:#{digest}"
    end
  end
end
