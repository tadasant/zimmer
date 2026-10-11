# frozen_string_literal: true

module Mcp
  module Tools
    # Upsert one record by key in this root's data store.
    class PutRootRecord < Tool
      include RootDataTool

      tool_name "put_root_record"

      description <<~DESC
        Write a record at `key` in a collection of **your agent root's persistent data store** — inserting it, or replacing the record already at that key. Use it for state with one current value: a cursor, a per-PR note, a cached result.

        `data` must be a JSON object of at most #{RootData::Limits::MAX_DATA_BYTES / 1.kilobyte} KB serialized, and must match the JSON Schema the collection declares in the catalog, if any. **Only declared collections can be written** (see `list_root_collections`). A replace is whole-record — fields you leave out are gone.

        Limits: #{RootData::Limits::MAX_RECORDS_PER_COLLECTION} records per collection, #{RootData::Limits::MAX_WRITES_PER_MINUTE} writes per collection per minute. The record's expiry is set from the collection's `retention_days` at the moment of each write.

        **Who wrote it is stamped, not stated**: the writing session comes from this MCP connection.

        **Returns** JSON: `created` (true for an insert, false for a replace) and the stored record.
      DESC

      input_schema({
        type: "object",
        properties: {
          collection: { type: "string", description: "A collection your root declares." },
          key: { type: "string", description: "The record's key, unique within the collection. Up to #{RootData::Limits::MAX_KEY_LENGTH} characters." },
          data: { type: "object", description: "The record. Replaces whatever is at this key." }
        },
        required: [ "collection", "key", "data" ]
      })

      def call(args)
        with_root_data do
          record, created = store.put(collection: require_collection(args), key: require_arg(args, "key"), data: args["data"])
          { created: created, record: record_json(record) }
        end
      end
    end
  end
end
