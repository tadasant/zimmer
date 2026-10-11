# frozen_string_literal: true

module Mcp
  module Tools
    # Query one collection of this root's data store. Structured, never SQL.
    class SearchRootRecords < Tool
      include RootDataTool

      tool_name "search_root_records"

      description <<~DESC
        Search one collection of **your agent root's persistent data store**.

        **`filter` is JSON containment** against each record's `data`: `{ "status": "open" }` matches every record whose data has `status` equal to `"open"`; `{ "tags": ["ci"] }` matches records whose `tags` array contains `"ci"`. Nested objects match the same way. Omit it for every record in the collection.

        **`order`**: `newest` (default), `oldest`, or `recently_updated`. **`limit`** defaults to #{RootData::Limits::DEFAULT_SEARCH_LIMIT} and caps at #{RootData::Limits::MAX_SEARCH_LIMIT}; page with `offset`. A page also stops early once it holds about #{RootData::Limits::SEARCH_RESPONSE_BUDGET_BYTES / 1.kilobyte} KB of record data, and says so with `truncated: true`.

        Reads do not need the collection to be declared — anything stored is readable.

        **Returns** JSON: `namespace`, `collection`, `records` (each with `id`, `key`, `data`, timestamps, `expires_at` and `writing_session_id`), `has_more`, `truncated`, and `next_offset` when there is more.
      DESC

      input_schema({
        type: "object",
        properties: {
          collection: { type: "string", description: "The collection to search." },
          filter: { type: "object", description: "JSON containment filter over each record's data. Omit for all records." },
          order: { type: "string", enum: RootData::Store::ORDERS.keys, description: "Sort order. Default: newest." },
          limit: { type: "integer", description: "Records per page. Default #{RootData::Limits::DEFAULT_SEARCH_LIMIT}, max #{RootData::Limits::MAX_SEARCH_LIMIT}." },
          offset: { type: "integer", description: "Records to skip, for paging. Default 0." }
        },
        required: [ "collection" ]
      })

      def call(args)
        with_root_data do
          collection = require_collection(args)
          result = store.search(
            collection: collection,
            filter: args["filter"],
            order: args["order"],
            limit: args["limit"] || RootData::Limits::DEFAULT_SEARCH_LIMIT,
            offset: args["offset"] || 0
          )

          {
            namespace: store.namespace,
            collection: collection,
            records: result[:records].map { |record| record_json(record) },
            has_more: result[:has_more],
            truncated: result[:truncated],
            next_offset: result[:next_offset]
          }.compact
        end
      end
    end
  end
end
