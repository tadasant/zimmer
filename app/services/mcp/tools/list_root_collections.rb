# frozen_string_literal: true

module Mcp
  module Tools
    # What this session's agent root can store, and what it has stored.
    class ListRootCollections < Tool
      include RootDataTool

      tool_name "list_root_collections"

      description <<~DESC
        List the collections in **your agent root's persistent data store**, and the limits on it.

        Root data is a small document store that outlives any one session: records your root's sessions write here are readable by every later session of the same root. Use it for state worth carrying between sessions — notes, run history, a cursor, a cache of something slow to recompute. It is not for secrets.

        **The namespace is your agent root's, and you do not choose it.** It is resolved from this session's agent root (or the root's `data_namespace` in the catalog). There is no argument for it on any root_data tool.

        **Collections are declared in the catalog**, under the root's `data_collections`, each with an optional JSON Schema and `retention_days`. Only a declared collection can be written. A collection that has records but is no longer declared is still listed and still readable and deletable.

        **Returns** JSON: `namespace`, `limits`, and per collection `declared`, `description`, `schema`, `retention_days`, `records`, `data_bytes` and `last_written_at`.
      DESC

      input_schema({ type: "object", properties: {}, required: [] })

      def call(_args)
        with_root_data do
          {
            namespace: store.namespace,
            limits: {
              max_data_bytes_per_record: RootData::Limits::MAX_DATA_BYTES,
              max_records_per_collection: RootData::Limits::MAX_RECORDS_PER_COLLECTION,
              max_collections: RootData::Limits::MAX_COLLECTIONS_PER_NAMESPACE,
              max_writes_per_minute_per_collection: RootData::Limits::MAX_WRITES_PER_MINUTE
            },
            collections: store.collections.map { |entry| collection_json(entry) }
          }
        end
      end

      private

      def collection_json(entry)
        declaration = entry[:declaration]
        counter = entry[:counter]
        {
          name: entry[:name],
          declared: !declaration.nil?,
          description: declaration&.description,
          schema: declaration&.schema,
          retention_days: declaration&.retention_days,
          records: counter&.records_count || 0,
          data_bytes: counter&.data_bytes || 0,
          last_written_at: counter&.last_written_at&.iso8601
        }
      end
    end
  end
end
