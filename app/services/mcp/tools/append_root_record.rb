# frozen_string_literal: true

module Mcp
  module Tools
    # Insert one keyless record into this root's data store.
    class AppendRootRecord < Tool
      include RootDataTool

      tool_name "append_root_record"

      description <<~DESC
        Append a new record, with no key, to a collection of **your agent root's persistent data store**. Use it for history: one record per run, per decision, per observation. Read them back newest-first with `search_root_records`.

        `data` must be a JSON object of at most #{RootData::Limits::MAX_DATA_BYTES / 1.kilobyte} KB serialized, and must match the JSON Schema the collection declares in the catalog, if any. **Only declared collections can be written** (see `list_root_collections`).

        Limits: #{RootData::Limits::MAX_RECORDS_PER_COLLECTION} records per collection, #{RootData::Limits::MAX_WRITES_PER_MINUTE} writes per collection per minute. A collection with `retention_days` drops records that old automatically.

        **Returns** JSON: the stored record, with its `id`.
      DESC

      input_schema({
        type: "object",
        properties: {
          collection: { type: "string", description: "A collection your root declares." },
          data: { type: "object", description: "The record." }
        },
        required: [ "collection", "data" ]
      })

      def call(args)
        with_root_data do
          record_json(store.append(collection: require_collection(args), data: args["data"]))
        end
      end
    end
  end
end
