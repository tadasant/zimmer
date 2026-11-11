# frozen_string_literal: true

module WorkBacklog
  # Delivers the decisions owed to the person who owes them, and is the one thing
  # that may renew a hold. See WorkBacklogItem::HOLD_DURATION for the design.
  #
  # == Why this exists
  #
  # From 2026-10-02 to 2026-11-05 the lapse page fired 8 times with this as the
  # only reminder a hold had (#1453). Each one started a triage chain whose only
  # move was to re-hold, and no decision was answered. The page told agents, and
  # the person who owed the decisions had no delivery path: the Issues page is
  # pull-only.
  #
  # == Why a renewal cannot become a silence
  #
  # Renewal is the receipt for a delivery. A hold gets a fresh HOLD_DURATION only
  # when a push listing it reached a device and the sweep has freshly re-read its
  # evidence unchanged. So a digest that crashes, loses its cron entry or reaches
  # nobody renews nothing: the hold lapses and WorkBacklog::LivenessSweep pages,
  # and none of those needs anything here to notice it. A delivery that reaches no
  # device also logs an ERROR on that tick, on a different path from the lapse page.
  #
  # The receipt is only as good as a push service accepting the message. The limits
  # of that are recorded in limitations.md rather than papered over here.
  #
  # == What is not renewed
  #
  # A row that does not fit in the push, whose latest read is `unknown`, or whose
  # evidence has not been read lately stays due, so the next tick tries it again,
  # and its clock keeps running. Changed evidence voids the hold in
  # WorkBacklogItem#record_liveness!, so such a row is never here at all.
  class DecisionDigest
    # How often an owed decision is re-sent. Under HOLD_DURATION by a full cadence,
    # so a delivery can fail every day for a week before a hold lapses.
    CADENCE = 7.days

    # How long a re-read of a row's evidence counts as fresh. A few dozen hourly
    # sweep passes: long enough to ride out a deploy, short enough that a sweep
    # that has stopped cannot have its readings renewed for it.
    EVIDENCE_MAX_AGE = 2.days

    # The daily tick lands a few seconds either side of where it landed a week ago.
    # Without this, losing that race would stretch a weekly digest to eight days.
    TICK_SLACK = 1.hour

    # A phone shows a few lines of this. Every reason is in full on the Issues page.
    REASON_LIMIT = 160

    # Web push payloads top out around 4KB once encrypted, and the service answers
    # an oversized one with a 413 that would read as a failed delivery.
    BODY_MAX_BYTES = 3000

    # Where a failed delivery's ERROR is remembered, so a failure that lasts pages
    # once per CADENCE rather than on every daily tick. A store that cannot remember
    # logs the ERROR every tick, which is the safe way round.
    FAILURE_PAGED_CACHE_KEY = "work_backlog_decision_digest:failure_paged"

    # Room kept for the "+N more" line.
    MORE_LINE_BYTES = 40

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
        rows = WorkBacklogItem.decision_owed(now: now).to_a
        return Result.new(outcome: :nothing_owed, rows: 0, renewed: 0) if rows.empty?
        return Result.new(outcome: :not_due, rows: rows.size, renewed: 0) unless rows.any? { |row| due?(row, now) }

        listed = fitting(least_recently_delivered(rows))
        reached, failures, faults = push(payload_for(listed, rows.size, now), channels)
        return report_failure(rows, failures) if reached.zero?

        renewed = record_delivery(listed, now)
        Rails.cache.delete(FAILURE_PAGED_CACHE_KEY)
        report_delivery(rows, reached, renewed, faults)
        Result.new(outcome: :delivered, rows: rows.size, renewed: renewed)
      end

      private

      # A hold nobody has been told about goes out on the next tick, so a new
      # decision reaches its owner within a day. Everything else waits out CADENCE.
      def due?(row, now)
        row.hold_digested_at.nil? || row.hold_digested_at <= now - CADENCE + TICK_SLACK
      end

      def least_recently_delivered(rows)
        rows.sort_by { |row| [ row.hold_digested_at&.to_f || 0, row.held_at.to_f, row.id ] }
      end

      # As many rows as fit, whole. The rest stay due and lead the next tick's push,
      # so a long list goes round over a few days and nothing is renewed unseen.
      def fitting(rows)
        bytes = 0
        rows.take_while do |row|
          bytes += line_for(row).bytesize + 1
          bytes <= BODY_MAX_BYTES - MORE_LINE_BYTES
        end
      end

      def line_for(row) = "#{row.key}: #{row.hold_reason.squish.truncate(REASON_LIMIT)}"

      # The tag is unique to the day because a notification that shares a tag
      # replaces the one showing, silently, and neither another Zimmer push nor last
      # week's unread digest should cost this one its place in the tray.
      def payload_for(listed, total, now)
        lines = listed.map { |row| line_for(row) }
        lines << "+#{total - listed.size} more on the Issues page" if listed.size < total
        {
          title: "#{total} #{'decision'.pluralize(total)} waiting on you",
          body: lines.join("\n"),
          url: DIGEST_URL,
          data: { notification_type: NOTIFICATION_TYPE, tag: "decision-digest-#{now.utc.to_date.iso8601}",
                  require_interaction: true }
        }
      end

      # How many devices took the push, across every channel. A push service
      # accepting the message is the strongest receipt on offer. Zero subscribers and
      # unconfigured channels both come back as zero, which is the point: nobody was
      # reached. `faults` is the subset that is broken rather than merely unconfigured.
      def push(payload, channels)
        failures = []
        faults = []
        reached = channels.sum do |name, channel|
          result = channel.call.send_to_all(**payload)
          sent = result[:sent].to_i
          if sent.zero?
            failures << "#{name}: #{result.except(:skipped).inspect}"
            faults << failures.last unless result[:skipped]
          end
          sent
        rescue StandardError => e
          failures << "#{name}: #{e.class}: #{e.message}"
          faults << failures.last
          0
        end
        [ reached, failures, faults ]
      end

      # One write, so `hold_digested_at` always names a delivery that renewed the
      # hold, and a row that was not renewed stays due. Conditional on the hold still
      # standing, so a row voided since the read above stays voided.
      def record_delivery(rows, now)
        WorkBacklogItem.where(id: rows.map(&:id)).where("held_until > ?", now)
                       .hold_renewable(read_since: now - EVIDENCE_MAX_AGE)
                       .update_all(held_until: now + WorkBacklogItem::HOLD_DURATION, hold_digested_at: now,
                                   updated_at: now)
      end

      # WARN when a channel is broken though another got through, because production
      # exports WARN and above: a dead phone behind a live laptop must leave a record.
      def report_delivery(rows, reached, renewed, faults)
        line = "[WorkBacklog::DecisionDigest] #{rows.size} decision(s) owed, delivered to " \
               "#{reached} device(s), #{renewed} hold(s) renewed"
        return Rails.logger.info(line) if faults.empty?

        Rails.logger.warn("#{line}; not reached: #{faults.join('; ')}")
      end

      # ERROR on purpose, and through Rails.logger rather than ErrorReporter: this
      # record is the page (`zimmer_backend_log_errors`), and reporting it to
      # GlitchTip as well would page `#alerts` twice for one failure. Later ticks of
      # the same failure stay at WARN until FAILURE_PAGED_CACHE_KEY expires.
      def report_failure(rows, failures)
        soonest = rows.map(&:held_until).min
        message = "[WorkBacklog::DecisionDigest] #{rows.size} owed decision(s) reached no device " \
                  "(#{failures.join('; ')}). Nothing was renewed, so these holds lapse and page, the first at " \
                  "#{soonest.utc.iso8601}. Check the VAPID keys, the APNs key and that a device is subscribed; " \
                  "the decisions are on the Issues page under Awaiting your decision."
        if Rails.cache.write(FAILURE_PAGED_CACHE_KEY, true, expires_in: CADENCE, unless_exist: true)
          Rails.logger.error(message)
        else
          Rails.logger.warn(message)
        end
        Result.new(outcome: :failed, rows: rows.size, renewed: 0)
      end
    end
  end
end
