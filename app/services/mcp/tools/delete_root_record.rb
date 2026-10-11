# frozen_string_literal: true

module Mcp
  module Tools
    # Delete one record, by key or id, from this root's data store.
    class DeleteRootRecord < Tool
      include RootDataTool

      tool_name "delete_root_record"

      description <<~DESC
        Delete one record from **your agent root's persistent data store**, by `key` or by `id`. Works on a collection the catalog no longer declares, so a root can always clean up after itself.

        **Returns** JSON: `deleted` (false when there was no such record — not an error) and, when one was deleted, the record as it was.
      DESC

      input_schema({
        type: "object",
        properties: {
          collection: { type: "string", description: "The collection the record is in." },
          key: { type: "string", description: "The record's key. Give this or id." },
          id: { type: "integer", description: "The record's id. Give this or key." }
        },
        required: [ "collection" ]
      })

      def call(args)
        with_root_data do
          record = store.delete(collection: require_collection(args), key: args["key"], id: args["id"])
          record ? { deleted: true, record: record_json(record) } : { deleted: false }
        end
      end
    end
  end
end
