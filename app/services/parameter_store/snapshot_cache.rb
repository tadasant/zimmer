# frozen_string_literal: true

module ParameterStore
  # A TTL'd, single-flighted, stale-on-error cache of a WHOLE namespace map.
  #
  # The grain is the map, not the key, because that is the grain the store reads
  # at: resolving a namespace is one list plus a render per parameter, so caching
  # per name would turn a page of ten `${VAR}`s into ten full listings.
  #
  # Four behaviours, each load-bearing:
  #
  #   * **Single flight** — concurrent readers share one refresh. Zimmer resolves
  #     secrets on the session-spawn path, which can fan out.
  #   * **Stale on error, only when a value is held.** A refresh that fails while
  #     we hold values serves the last known good ones and warns. A COLD failure
  #     re-raises: pretending an unreachable store is an empty one turns an outage
  #     into "that secret does not exist".
  #   * **Failure backoff** — after a failure, do not re-attempt on every request.
  #   * **Generation counter** — an `invalidate` during an in-flight refresh
  #     discards that refresh's result, so a write is never masked by a read that
  #     started before it.
  class SnapshotCache
    DEFAULT_TTL = 60.seconds
    FAILURE_BACKOFF = 5.seconds

    Entry = Struct.new(:values, :fetched_at, :generation, :last_failure_at, keyword_init: true)

    def initialize(ttl: DEFAULT_TTL, &loader)
      @ttl = ttl
      @loader = loader
      @entries = {}
      @locks = Hash.new { |hash, key| hash[key] = Mutex.new }
      @guard = Mutex.new
    end

    # Values for `key`, refreshing when stale.
    # @return [Hash{String => String}]
    def get(key)
      refresh(key) if stale?(key)
      entry(key)&.values || {}
    end

    # Values for `key` without refreshing. nil when nothing is held.
    def peek(key)
      entry(key)&.values
    end

    # Seconds since `key` was last successfully loaded; Float::INFINITY if never.
    def age(key)
      current = entry(key)
      return Float::INFINITY if current.nil?

      Time.current - current.fetched_at
    end

    # Drop what is held for `key` (or everything) and bump the generation so a
    # refresh already in flight will not commit its result.
    def invalidate(key = nil)
      @guard.synchronize do
        keys = key ? [ key ] : @entries.keys
        keys.each do |k|
          existing = @entries[k]
          @entries[k] = Entry.new(values: nil, fetched_at: nil,
            generation: (existing&.generation || 0) + 1)
        end
      end
    end

    # Load `key`, honouring single-flight and the failure backoff.
    #
    # `force:` is what the negative-TTL miss path needs. That path fires when the
    # snapshot is FRESH but does not hold the name asked for — so a staleness
    # check here would decline to reload every time, and a newly-added secret
    # would stay invisible for a full TTL instead of the negative TTL. The
    # staleness double-check is still right for the ordinary path, where it stops
    # a queue of threads from each re-reading what the first one just fetched.
    def refresh(key, force: false)
      lock(key).synchronize do
        # Another thread may have refreshed while this one waited on the lock.
        return if !force && !stale?(key)

        existing = entry(key)
        if existing&.last_failure_at && held?(key) &&
            Time.current - existing.last_failure_at < FAILURE_BACKOFF
          return
        end

        generation = @guard.synchronize { @entries[key]&.generation || 0 }

        begin
          values = @loader.call(key)
        rescue => e
          record_failure(key, e)
          return
        end

        @guard.synchronize do
          # A concurrent invalidate happened; discard this now-stale read.
          next if (@entries[key]&.generation || 0) != generation

          @entries[key] = Entry.new(values: values, fetched_at: Time.current, generation: generation)
        end
      end
    end

    private

    def lock(key)
      @guard.synchronize { @locks[key] }
    end

    def entry(key)
      @guard.synchronize do
        found = @entries[key]
        found&.fetched_at ? found : nil
      end
    end

    def held?(key) = !entry(key).nil?

    def stale?(key)
      current = entry(key)
      current.nil? || Time.current - current.fetched_at >= @ttl
    end

    def record_failure(key, error)
      current = entry(key)
      # Nothing held: the caller must see the outage rather than an empty map.
      raise error if current.nil?

      @guard.synchronize do
        @entries[key] = Entry.new(values: current.values, fetched_at: current.fetched_at,
          generation: current.generation, last_failure_at: Time.current)
      end
      # Only the class and a StoreError's own message are logged. Other error
      # messages (a JSON parse error, say) can embed a window of the body, and on
      # this path the body is a rendered secret.
      summary = error.is_a?(StoreError) ? "#{error.class}: #{error.message}" : error.class.to_s
      Rails.logger.warn "[ParameterStore] refresh of #{key} failed; serving last known good values (#{summary})"
    end
  end
end
