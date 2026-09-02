# frozen_string_literal: true

module WorkBacklog
  # The ONE way a queued item is created by a live writer — the MCP tool and the
  # REST create action both come through here, so the two cannot disagree about
  # what an item is, where it lands, or what "already queued" means. (The
  # importer is the other creator, and it deliberately bypasses the ranking so
  # the file's precedences arrive verbatim.)
  #
  # IDEMPOTENT ON `key`. If a QUEUED item with this key exists, nothing is
  # written and that item is returned with `created: false` — a second gate
  # session on the same issue must not double-queue it. A started or removed
  # row with the same key does not block: that is history, and the same issue
  # can legitimately be cleared again after the session that first took it came
  # to nothing.
  #
  # PLACEMENT IS THE RANKING'S, NOT THE CALLER'S — unless the caller is a human
  # hand-placing the item, which is the `pinned: true` + `precedence:` pair the
  # REST action may pass. The MCP tool has no such arguments.
  class Append
    class InvalidItem < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.join("; "))
      end
    end

    Result = Data.define(:item, :created, :respaced, :position) do
      def created? = created
    end

    # The item fields a caller may set. Everything else on the row is stamped.
    ATTRIBUTE_KEYS = %w[key issue_url repo surface title kind scope_direction estimated_cost
                        gate_verdict decided_at added_by].freeze

    class << self
      # @param attributes [Hash] string-keyed: the ATTRIBUTE_KEYS plus the payload
      #   fields (`ratings`, `prompt`, `notes`, `gate_session`) and anything else
      #   the gate wants kept, which rides in `payload`
      # @param added_via [String] WorkBacklogItem::MCP / API
      # @param writing_session [Session, nil] resolved at the caller's boundary —
      #   from the MCP connection, or a self-declared `acting_session_id` on REST
      # @param placement [Hash, nil] `{ "precedence" => Integer, "pinned" => true }`
      #   for a human hand-placing the item on create. Nil means "by the rules".
      # @return [Result]
      def call(attributes, added_via:, writing_session: nil, placement: nil)
        attributes = attributes.to_h.deep_stringify_keys
        key = attributes["key"].to_s.strip
        raise InvalidItem, "key is required" if key.blank?

        Ranking.with_lock do
          existing = WorkBacklogItem.queued.find_by(key: key)
          return Result.new(item: existing, created: false, respaced: false, position: position_of(existing)) if existing

          item = build(attributes, key: key, added_via: added_via, writing_session: writing_session)
          # Validated BEFORE placement, with a placeholder rank, so a malformed
          # item is refused with every model error rather than with whatever the
          # ranking tripped over first (an unknown cost, say).
          item.precedence = 0
          raise InvalidItem, item.errors.full_messages if item.invalid?

          respaced = assign_precedence!(item, placement)
          item.save!
          Ranking.rerank!

          Result.new(item: item.reload, created: true, respaced: respaced, position: position_of(item))
        end
      rescue ActiveRecord::RecordInvalid => e
        raise InvalidItem, e.record.errors.full_messages
      rescue Ranking::BandFull => e
        raise InvalidItem, e.message
      end

      # 1-based rank among queued items, or nil once the item is no longer queued.
      def position_of(item)
        return nil unless item.queued?

        WorkBacklogItem.queued.in_rank_order.pluck(:id).index(item.id)&.succ
      end

      private

      def build(attributes, key:, added_via:, writing_session:)
        # The columns the caller may set, minus the ones assigned explicitly below.
        column_attrs = attributes.slice(*ATTRIBUTE_KEYS).compact.except("key", "issue_url", "decided_at", "added_by")
        payload = attributes.except(*ATTRIBUTE_KEYS, "precedence", "pinned", "added_via", "status",
                                    "writing_session_id", "acting_session_id")

        WorkBacklogItem.new(
          **column_attrs.symbolize_keys,
          key: key,
          issue_url: attributes["issue_url"].presence,
          decided_at: parse_date(attributes["decided_at"]),
          added_at: Time.current,
          added_by: attributes["added_by"].presence || default_added_by(added_via, writing_session),
          added_via: added_via,
          writing_session: writing_session,
          status: WorkBacklogItem::QUEUED,
          payload: payload
        )
      end

      # A human hand-placement is honoured verbatim and pinned; anything else is
      # placed by the band rules.
      def assign_precedence!(item, placement)
        placement = placement.to_h.deep_stringify_keys
        raw = placement["pinned"]
        pinned = raw.nil? || raw.to_s.strip.empty? ? false : ActiveModel::Type::Boolean.new.cast(raw)
        raise InvalidItem, "pinned must be true or false (got #{raw.inspect})" if pinned.nil?

        if pinned
          raise InvalidItem, "a pinned item needs an explicit precedence" if placement["precedence"].blank?

          item.precedence = Integer(placement["precedence"])
          item.pinned = true
          return false
        end

        placed = Ranking.place(item.estimated_cost)
        item.precedence = placed.precedence
        item.pinned = false
        placed.respaced
      rescue ArgumentError => e
        raise InvalidItem, e.message
      end

      # The session's agent root is the most honest name for "who appended" —
      # it is what the file recorded (`issue-work-gate`) and it comes from the
      # connection rather than from the caller. With no session on the
      # connection, the surface itself is the writer.
      def default_added_by(added_via, writing_session)
        writing_session&.metadata&.dig("agent_root_key").presence || added_via
      end

      def parse_date(value)
        return nil if value.blank?
        return value if value.is_a?(Date)

        Date.iso8601(value.to_s)
      rescue Date::Error
        raise InvalidItem, "decided_at must be an ISO date (got #{value.inspect})"
      end
    end
  end
end
