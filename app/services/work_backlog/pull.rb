# frozen_string_literal: true

module WorkBacklog
  # The groomer's pull: take items off the top of the queue and start them.
  #
  # `WORK_BACKLOG.md`'s pull protocol, minus the file handling. The groomer
  # decides HOW MANY (its WIP ceiling arithmetic is its own — this refuses more
  # than MAX per call so one bad night is bounded) and, having re-checked each
  # candidate on GitHub, WHICH: either "the top N" or an explicit list of keys it
  # read and vetted. Each pulled item becomes a `spot` `zimmer-router` session via
  # WorkBacklog::Start, in one transaction with the status change.
  #
  # THE ONE REMOVAL AN AGENT MAY MAKE. An item whose issue turns out to be dead at
  # pull time — closed, already carrying an open PR, already being worked, or
  # failing the trust re-check — is removed with the reason, which must be one of
  # WorkBacklogItem::MECHANICAL_REMOVAL_REASONS. That is bookkeeping about a fact
  # the puller observed, not a judgement about the work; discretionary removal is
  # a human's and has no path here.
  #
  # RANK IS CARRIED FORWARD. The n-th item started gets a spot precedence of the
  # acting session's own plus (count − n + 1), so the top item runs first and the
  # spawned tree stays contiguous with its parent — the groomer's rule.
  #
  # RETRY SAFETY. `keys` is safe to retry after an error: a key that was already
  # started fails cleanly as "not queued". `count` is not — a retry starts the
  # NEXT N — which is why a post-commit callback raising after the items are
  # already started is caught and the committed result returned (the same
  # reasoning as WorkBacklog::Start), and why the tool description says so.
  class Pull
    MAX = 10

    class InvalidPull < StandardError; end

    Started = Data.define(:item, :session)
    Removed = Data.define(:item, :reason)
    Result = Data.define(:started, :removed)

    class << self
      # @param count [Integer, nil] start the top N queued items
      # @param keys [Array<String>, nil] start exactly these queued items, in the
      #   order given (a key that is not queued fails the whole pull)
      # @param dead [Array<Hash>] `[{ "key" => …, "reason" => … }]` items to remove
      #   instead of start; `reason` from MECHANICAL_REMOVAL_REASONS
      # @param acting_session [Session, nil] the puller, from the caller's boundary
      # @param removed_by [String] who to record on a removal when there is no
      #   acting session ("api" / "mcp")
      # @return [Result]
      def call(count: nil, keys: nil, dead: [], acting_session: nil, removed_by: "api")
        keys = Array(keys).map { |k| k.to_s.strip }.reject(&:blank?)
        dead = Array(dead).map { |d| d.to_h.deep_stringify_keys }
        count = count.nil? ? nil : Integer(count)
        validate!(count, keys, dead)

        result = nil
        Ranking.with_lock do
          removed = remove_dead(dead, acting_session: acting_session, removed_by: removed_by)
          candidates = keys.any? ? by_keys(keys) : top(count.to_i)
          started = candidates.each_with_index.map do |item, index|
            start = Start.call(
              item: item,
              scheduling_class: SessionGenesis::SPOT,
              acting_session: acting_session,
              precedence: carried_precedence(acting_session, candidates.size, index + 1)
            )
            Started.new(item: start.item, session: start.session)
          end

          # Every writer re-ranks, a pull of zero included: that is the groomer's
          # nightly chance to fix drift even on a night it pulls nothing.
          Ranking.rerank!

          result = Result.new(started: started, removed: removed)
        end
        result
      rescue ArgumentError, TypeError => e
        raise InvalidPull, e.message
      rescue StandardError => e
        raise unless result && committed?(result)

        Rails.logger.warn("[WorkBacklog::Pull] #{result.started.size} item(s) started, but a post-commit " \
                          "callback raised: #{e.class}: #{e.message}")
        result
      end

      def committed?(result)
        result.started.all? { |s| Start.committed?(s) } &&
          result.removed.all? { |r| WorkBacklogItem.removed.exists?(id: r.item.id) }
      end

      private

      def validate!(count, keys, dead)
        if count.nil? && keys.empty? && dead.empty?
          raise InvalidPull, "pass count (the top N), keys (specific queued items), or dead (items to remove)"
        end
        raise InvalidPull, "pass count or keys, not both" if count && keys.any?
        raise InvalidPull, "count must be between 0 and #{MAX}" if count && !(0..MAX).cover?(count)
        raise InvalidPull, "at most #{MAX} keys per pull" if keys.size > MAX
        raise InvalidPull, "keys must not repeat" if keys.uniq.size != keys.size

        dead.each do |entry|
          raise InvalidPull, "each dead entry needs a key" if entry["key"].blank?
          reason = entry["reason"].to_s
          unless WorkBacklogItem::MECHANICAL_REMOVAL_REASONS.include?(reason)
            raise InvalidPull, "dead[#{entry['key']}].reason must be one of " \
                               "#{WorkBacklogItem::MECHANICAL_REMOVAL_REASONS.join(', ')} (got #{reason.inspect}); " \
                               "a removal for any other reason is a human's call and has no agent path"
          end
          if keys.include?(entry["key"].to_s)
            raise InvalidPull, "#{entry['key']} is listed both as dead and as a key to start"
          end
        end
      end

      def remove_dead(dead, acting_session:, removed_by:)
        dead.map do |entry|
          item = WorkBacklogItem.queued.lock.find_by(key: entry["key"].to_s)
          raise InvalidPull, "#{entry['key']} is not queued, so it cannot be removed" unless item

          by = acting_session ? "session:#{acting_session.id}" : removed_by
          item.remove!(reason: entry["reason"], by: by)
          Removed.new(item: item, reason: entry["reason"])
        end
      end

      def by_keys(keys)
        found = WorkBacklogItem.queued.where(key: keys).index_by(&:key)
        missing = keys - found.keys
        raise InvalidPull, "not queued: #{missing.join(', ')}" if missing.any?

        keys.map { |key| found.fetch(key) }
      end

      def top(count)
        WorkBacklogItem.queued.in_rank_order.limit(count).to_a
      end

      # `<the groomer's own precedence> + (pull_count − n + 1)`. Without an acting
      # session there is nothing to be contiguous with, and SessionPrecedence
      # picks a default.
      def carried_precedence(acting_session, pull_count, n)
        return nil unless acting_session

        Session.clamp_precedence(acting_session.precedence.to_i + (pull_count - n + 1))
      end
    end
  end
end
