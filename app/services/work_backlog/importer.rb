# frozen_string_literal: true

module WorkBacklog
  # The one-time import of `WORK_BACKLOG.json` into `work_backlog_items`.
  #
  # IDEMPOTENT, KEYED ON THE ITEM'S `id`. A key that already has a row — in ANY
  # status, so an item the fleet has since started or a human has since removed
  # is not resurrected — is counted as already present and skipped. Nothing is
  # edited and nothing is deleted, here or in the source file, so it is safe to
  # run before anything else writes and safe to run again after.
  #
  # PRECEDENCE ARRIVES VERBATIM. The file is stored sorted by precedence, and the
  # point of the import is that the queue comes out in the same order it went in.
  # So the ranking is not consulted and no re-rank runs: the numbers are the
  # file's numbers. Every unpinned item in the file already sits inside its band
  # (the file's own validator enforces the floors), so the first live append
  # finds nothing to move.
  #
  # ONE ITEM IT CANNOT IMPORT DOES NOT COST THE REST. It is counted as rejected,
  # named with its reason, and the pass continues — the alternative is a task
  # that fails on one malformed entry, backs off, re-fetches, and fails
  # identically forever.
  class Importer
    Rejection = Data.define(:key, :reason)
    Result = Data.define(:seen, :imported, :already_present, :rejected, :rejections) do
      def to_h
        { seen: seen, imported: imported, already_present: already_present, rejected: rejected,
          rejections: rejections.map { |r| "#{r.key}: #{r.reason}" } }
      end
    end

    def initialize(source:, logger: Rails.logger)
      @source = source
      @logger = logger
    end

    # @return [Result]
    def call
      items = @source.items
      imported = already = 0
      rejections = []

      items.each do |raw|
        key = raw["id"].to_s.strip
        if key.blank?
          rejections << Rejection.new(key: "(no id)", reason: "item has no id")
          next
        end

        outcome, reason = import(key, raw)
        case outcome
        when :imported then imported += 1
        when :present then already += 1
        else rejections << Rejection.new(key: key, reason: reason)
        end
      end

      rejections.each { |r| @logger.warn("[WorkBacklog::Importer] rejected #{r.key}: #{r.reason}") }
      @logger.info("[WorkBacklog::Importer] #{@source.describe}: #{items.size} seen, #{imported} imported, " \
                   "#{already} already present, #{rejections.size} rejected")

      Result.new(seen: items.size, imported: imported, already_present: already,
                 rejected: rejections.size, rejections: rejections)
    end

    # The row an item becomes. Public so a test can check the mapping directly.
    def self.attributes_for(raw)
      raw = raw.to_h.deep_stringify_keys
      {
        key: raw["id"].to_s.strip,
        issue_url: raw["issue"].presence,
        repo: raw["repo"],
        surface: raw["surface"],
        title: raw["title"],
        kind: raw["kind"],
        scope_direction: raw["scope_direction"],
        estimated_cost: raw["estimated_cost"],
        gate_verdict: raw["gate_verdict"].presence,
        decided_at: parse_date(raw["decided_at"]),
        # A date in the file; a timestamp here. Midnight UTC on that date keeps
        # the trend chart honest about when the item joined the queue.
        added_at: parse_date(raw["added_at"])&.in_time_zone("UTC")&.beginning_of_day || Time.current,
        added_by: raw["added_by"].presence || "queue-migration",
        added_via: WorkBacklogItem::IMPORT,
        precedence: raw["precedence"],
        pinned: raw["pinned"] == true,
        status: WorkBacklogItem::QUEUED,
        payload: raw.except(*WorkBacklogItem::PROMOTED_KEYS)
      }
    end

    def self.parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    private

    # `[:imported]`, `[:present]`, or `[:rejected, reason]`. The INSERT gets its
    # own savepoint so a failure does not poison the caller's transaction, and a
    # unique violation from a concurrent pass reads as present.
    def import(key, raw)
      return [ :present ] if WorkBacklogItem.exists?(key: key)

      item = WorkBacklogItem.new(self.class.attributes_for(raw))
      return [ :rejected, item.errors.full_messages.join("; ") ] if item.invalid?

      WorkBacklogItem.transaction(requires_new: true) { item.save! }
      [ :imported ]
    rescue ActiveRecord::RecordNotUnique
      [ :present ]
    rescue ActiveRecord::RecordInvalid => e
      [ :rejected, e.record.errors.full_messages.join("; ") ]
    rescue ArgumentError, TypeError => e
      [ :rejected, e.message ]
    end
  end
end
