# frozen_string_literal: true

module WorkBacklog
  # Delivers the decisions owed to the person who owes them, and is the one thing
  # that may renew a hold. See WorkBacklogItem::HOLD_DURATION for the design.
  #
  # == Why this exists
  #
  # A hold used to lapse into one `#alerts` page per fortnight, and that page was
  # the only reminder. From 2026-10-02 to 2026-11-05 it fired 8 times (#1453). Each
  # one started a triage chain whose only move was to re-hold, and no decision was
  # answered. The page told agents, and the person who owed the decisions had no
  # delivery path at all: the Issues page is pull-only.
  #
  # == Why a renewal cannot become a silence
  #
  # Renewal is the receipt for a delivery. A hold gets a fresh HOLD_DURATION only
  # when a push reached at least one device with that hold in it, so every way
  # this can break ends the same way: nothing renews the hold, it lapses, and
  # WorkBacklog::LivenessSweep pages on the lapse exactly as it always did. That
  # covers a push nobody receives, this job crashing, and the cron entry
  # disappearing, none of which needs anything here to notice it. A failed
  # delivery also logs an ERROR on the next tick after it fails, which is the
  # `zimmer_backend_log_errors` Grafana rule, so it does not wait for the lapse and
  # does not travel the GlitchTip path the lapse page does.
  #
  # == What is not renewed
  #
  # A row whose latest read is `unknown` stays in the digest but keeps its clock:
  # a renewal says the evidence was re-read and has not changed, and nobody read
  # it. A row GitHub keeps answering nothing for therefore lapses and pages.
  # Changed evidence voids the hold in WorkBacklogItem#record_liveness!, so such a
  # row is never here at all.
  class DecisionDigest
    # How often an owed decision is re-sent. Under HOLD_DURATION by a full cadence,
    # so one missed digest costs nothing and the second costs a page.
    CADENCE = 7.days

    # The daily tick lands a few seconds either side of where it landed a week ago.
    # Without this, losing that race would stretch a weekly digest to eight days.
    TICK_SLACK = 1.hour

    # A phone shows a few lines of this. The rest is one tap away on the Issues
    # page, which has every reason in full.
    REASON_LIMIT = 160

    # Web push payloads top out around 4KB once encrypted, and the service answers
    # an oversized one with a 413 that would read as a failed delivery.
    BODY_MAX_BYTES = 3000

    DIGEST_URL = "/issues"
    NOTIFICATION_TYPE = "decision_digest"

    # Both of Zimmer's push paths. Built lazily so a channel that cannot even be
    # constructed is one failed channel rather than an aborted digest.
    CHANNELS = { web_push: -> { WebPushService.new }, ios: -> { ApnsService.new } }.freeze

    # `outcome` is :nothing_owed, :not_due, :delivered or :failed.
    Result = Data.define(:outcome, :rows, :renewed)

    class << self
      # @param now [Time]
      # @param channels [Hash{Symbol => #call}] see CHANNELS
      # @return [Result]
      def deliver!(now: Time.current, channels: CHANNELS)
        rows = WorkBacklogItem.decision_owed(now: now).order(:held_at, :id).to_a
        return Result.new(outcome: :nothing_owed, rows: 0, renewed: 0) if rows.empty?
        return Result.new(outcome: :not_due, rows: rows.size, renewed: 0) unless due?(rows, now)

        reached, failures = push(payload_for(rows), channels)
        return report_failure(rows, failures) if reached.zero?

        renewed = record_delivery(rows, now)
        Rails.logger.info("[WorkBacklog::DecisionDigest] #{rows.size} decision(s) owed, delivered to " \
                          "#{reached} device(s), #{renewed} hold(s) renewed#{"; not reached: #{failures.join('; ')}" if failures.any?}")
        Result.new(outcome: :delivered, rows: rows.size, renewed: renewed)
      end

      private

      # A hold nobody has been told about goes out on the next tick, so a new
      # decision reaches its owner within a day. Everything else waits out CADENCE.
      def due?(rows, now)
        rows.any? { |row| row.hold_digested_at.nil? || row.hold_digested_at <= now - CADENCE + TICK_SLACK }
      end

      def payload_for(rows)
        lines = rows.map { |row| "#{row.key}: #{row.hold_reason.squish.truncate(REASON_LIMIT)}" }
        {
          title: "#{rows.size} #{'decision'.pluralize(rows.size)} waiting on you",
          body: lines.join("\n").truncate_bytes(BODY_MAX_BYTES),
          url: DIGEST_URL,
          data: { notification_type: NOTIFICATION_TYPE }
        }
      end

      # How many devices took the push, across every channel. A push service
      # accepting the message is the strongest receipt on offer. Nothing says a
      # person read it. Zero subscribers and unconfigured channels both come back
      # as zero, which is the point: nobody was reached.
      def push(payload, channels)
        failures = []
        reached = channels.sum do |name, channel|
          result = channel.call.send_to_all(**payload)
          failures << "#{name}: #{result.except(:skipped).inspect}" if result[:sent].to_i.zero?
          result[:sent].to_i
        rescue StandardError => e
          failures << "#{name}: #{e.class}: #{e.message}"
          0
        end
        [ reached, failures ]
      end

      # Conditional on the hold still standing, so a row voided since the read
      # above stays voided. Renewal sits behind the delivery on purpose: see the
      # class comment.
      def record_delivery(rows, now)
        delivered = WorkBacklogItem.where(id: rows.map(&:id)).where("held_until > ?", now)
        WorkBacklogItem.transaction do
          renewed = delivered.hold_renewable.update_all(held_until: now + WorkBacklogItem::HOLD_DURATION)
          delivered.update_all(hold_digested_at: now, updated_at: now)
          renewed
        end
      end

      # ERROR on purpose, and through Rails.logger rather than ErrorReporter: this
      # record is the page (`zimmer_backend_log_errors`), and reporting it to
      # GlitchTip as well would page `#alerts` twice for one failure. Unrenewed
      # rows stay due, so a failure that lasts repeats on every daily tick.
      def report_failure(rows, failures)
        soonest = rows.map(&:held_until).min
        Rails.logger.error(
          "[WorkBacklog::DecisionDigest] #{rows.size} owed decision(s) reached no device " \
          "(#{failures.join('; ')}). Nothing was renewed, so these holds lapse and page, the first at " \
          "#{soonest.utc.iso8601}. Check the VAPID keys, the APNs key and that a device is subscribed; " \
          "the decisions are on the Issues page under Awaiting your decision."
        )
        Result.new(outcome: :failed, rows: rows.size, renewed: 0)
      end
    end
  end
end
