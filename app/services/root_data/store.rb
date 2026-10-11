# frozen_string_literal: true

module RootData
  # Every read and write of one namespace's records. The namespace is fixed at
  # construction — resolved by RootData::Namespace — so no method here takes one.
  #
  # LOCK ORDER. Every write locks the collection's AgentRootRecordCounter row
  # first and touches records second; RootDataRetentionJob does the same. That
  # one order is what lets the row cap, the rate limit and the counters hold
  # under concurrent writers without deadlocking against the sweep.
  class Store
    class Refused < StandardError; end

    ORDERS = {
      "newest" => { created_at: :desc, id: :desc },
      "oldest" => { created_at: :asc, id: :asc },
      "recently_updated" => { updated_at: :desc, id: :desc }
    }.freeze

    attr_reader :namespace

    # @param namespace [String]
    # @param root [AgentRootsConfig::AgentRoot] whose `data_collections` a write is checked against
    # @param writing_session [Session, nil] stamped on every row this store writes
    def initialize(namespace:, root:, writing_session: nil, now: Time.current)
      @namespace = namespace
      @root = root
      @writing_session = writing_session
      @now = now
    end

    def self.for(resolved)
      new(namespace: resolved.namespace, root: resolved.root, writing_session: resolved.session)
    end

    def declarations
      @declarations ||= Collections.declared(@root)
    end

    # --- Writes ---------------------------------------------------------------

    # Insert or replace the record at `key`. Returns [record, created?].
    def put(collection:, key:, data:)
      key = normalize_key!(key)
      write(collection, data) do |declaration, bytes, counter|
        record = scope(collection).find_by(key: key)
        if record
          counter.data_bytes += bytes - record.data_bytes
          record.update!(data: data, data_bytes: bytes, expires_at: declaration.expires_at(@now),
                         writing_session: @writing_session, updated_at: @now)
          [ record, false ]
        else
          [ insert!(counter, collection, key, data, bytes, declaration), true ]
        end
      end
    end

    # Insert a keyless record.
    def append(collection:, data:)
      write(collection, data) do |declaration, bytes, counter|
        insert!(counter, collection, nil, data, bytes, declaration)
      end
    end

    # Delete one record by key or id. Returns the deleted record, or nil when
    # there was nothing to delete. Allowed on undeclared collections, so a root
    # can always clean up after a collection it stopped declaring.
    def delete(collection:, key: nil, id: nil)
      AgentRootRecord.transaction do
        counter = AgentRootRecordCounter.lock.find_by(namespace: namespace, collection: collection.to_s)
        next nil unless counter

        record = locate(collection, key: key, id: id)
        next nil unless record

        take_rate_slot!(counter)
        record.delete
        counter.records_count = [ counter.records_count - 1, 0 ].max
        counter.data_bytes = [ counter.data_bytes - record.data_bytes, 0 ].max
        counter.last_written_at = @now
        counter.save!
        record
      end
    end

    # --- Reads ----------------------------------------------------------------
    #
    # Never consult the declarations: what is stored is readable whether or not
    # the catalog in hand still declares it.

    def get(collection:, key: nil, id: nil)
      locate(collection, key: key, id: id)
    end

    # @return [Hash] { records:, has_more:, truncated:, next_offset: }
    def search(collection:, filter: nil, order: "newest", limit: Limits::DEFAULT_SEARCH_LIMIT, offset: 0)
      order_by = ORDERS[order.presence || "newest"] ||
        raise(Refused, "Unknown order #{order.inspect}. Use one of: #{ORDERS.keys.join(', ')}.")
      limit = limit.to_i.clamp(1, Limits::MAX_SEARCH_LIMIT)
      offset = [ offset.to_i, 0 ].max

      relation = scope(collection)
      unless filter.nil?
        raise Refused, "filter must be a JSON object, matched by containment against each record's data." unless filter.is_a?(Hash)

        relation = relation.containing(filter) if filter.any?
      end

      rows = relation.order(order_by).offset(offset).limit(limit + 1).to_a
      has_more = rows.size > limit
      rows = rows.first(limit)

      # Stop at the response budget rather than return megabytes, and say so.
      kept = []
      spent = 0
      rows.each do |row|
        break if kept.any? && spent + row.data_bytes > Limits::SEARCH_RESPONSE_BUDGET_BYTES

        kept << row
        spent += row.data_bytes
      end
      truncated = kept.size < rows.size

      {
        records: kept,
        has_more: has_more || truncated,
        truncated: truncated,
        next_offset: (has_more || truncated) ? offset + kept.size : nil
      }
    end

    # Every collection this namespace declares or has stored records in, with
    # its usage. Read from the counters, not the records table.
    def collections
      counters = AgentRootRecordCounter.for_namespace(namespace).index_by(&:collection)
      (declarations.keys | counters.keys).sort.map do |name|
        { name: name, declaration: declarations[name], counter: counters[name] }
      end
    end

    private

    def scope(collection)
      AgentRootRecord.in_collection(namespace, collection.to_s)
    end

    def locate(collection, key:, id:)
      if key.present?
        scope(collection).find_by(key: key.to_s)
      elsif id.present?
        scope(collection).find_by(id: id)
      else
        raise Refused, "Pass either key or id."
      end
    end

    def normalize_key!(key)
      key = key.to_s.strip
      raise Refused, "key must be a non-empty string." if key.empty?
      if key.length > Limits::MAX_KEY_LENGTH
        raise Refused, "key is #{key.length} characters; the limit is #{Limits::MAX_KEY_LENGTH}."
      end

      key
    end

    # Validate, then lock the collection's counter and yield inside one
    # transaction. Everything that can refuse without the database refuses
    # before the transaction opens.
    def write(collection, data)
      collection = collection.to_s
      declaration = declarations[collection]
      unless declaration
        declared = declarations.keys
        raise Refused, "Collection \"#{collection}\" is not declared by agent root \"#{@root.name}\", so it cannot " \
                       "be written. Declared collections: #{declared.any? ? declared.join(', ') : '(none)'}. " \
                       "Collections are declared in the catalog, under the root's data_collections."
      end

      raise Refused, "data must be a JSON object." unless data.is_a?(Hash)

      bytes = data.to_json.bytesize
      if bytes > Limits::MAX_DATA_BYTES
        raise Refused, "data is #{bytes} bytes serialized; the limit is #{Limits::MAX_DATA_BYTES} per record."
      end

      errors = Collections.schema_errors(declaration, data)
      if errors.any?
        raise Refused, "data does not match the schema declared for \"#{collection}\": #{errors.join('; ')}"
      end

      AgentRootRecord.transaction do
        counter = lock_counter!(collection)
        take_rate_slot!(counter)
        result = yield(declaration, bytes, counter)
        counter.last_written_at = @now
        counter.save!
        result
      end
    end

    def insert!(counter, collection, key, data, bytes, declaration)
      if counter.records_count >= Limits::MAX_RECORDS_PER_COLLECTION
        raise Refused, "Collection \"#{collection}\" holds #{counter.records_count} records, the limit. " \
                       "Delete some, or put by key to replace one instead."
      end

      record = AgentRootRecord.create!(
        namespace: namespace, collection: collection, key: key, data: data, data_bytes: bytes,
        expires_at: declaration.expires_at(@now), writing_session: @writing_session,
        created_at: @now, updated_at: @now
      )
      counter.records_count += 1
      counter.data_bytes += bytes
      record
    end

    def lock_counter!(collection)
      counter = AgentRootRecordCounter.lock.find_by(namespace: namespace, collection: collection)
      return counter if counter

      existing = AgentRootRecordCounter.for_namespace(namespace).count
      if existing >= Limits::MAX_COLLECTIONS_PER_NAMESPACE
        raise Refused, "Namespace \"#{namespace}\" already has #{existing} collections, the limit."
      end

      AgentRootRecordCounter.create_or_find_by!(namespace: namespace, collection: collection).tap(&:lock!)
    end

    def take_rate_slot!(counter)
      if counter.window_started_at && counter.window_started_at > @now - Limits::RATE_WINDOW
        if counter.window_writes >= Limits::MAX_WRITES_PER_MINUTE
          raise Refused, "Collection \"#{counter.collection}\" has taken #{counter.window_writes} writes in the " \
                         "last minute, the limit. Try again after #{(counter.window_started_at + Limits::RATE_WINDOW).utc.iso8601}."
        end

        counter.window_writes += 1
      else
        counter.window_started_at = @now
        counter.window_writes = 1
      end
    end
  end
end
