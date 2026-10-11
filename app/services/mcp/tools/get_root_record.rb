# frozen_string_literal: true

module Mcp
  module Tools
    # One record of this root's data store, by key or id.
    class GetRootRecord < Tool
      include RootDataTool

      tool_name "get_root_record"

      description <<~DESC
        Read one record from **your agent root's persistent data store**, by `key` (for records written with `put_root_record`) or by `id`.

        **Returns** JSON: the record — `id`, `key`, `data`, timestamps, `expires_at`, `writing_session_id` — or an error when there is no such record in this root's namespace.
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
          collection = require_collection(args)
          record = store.get(collection: collection, key: args["key"], id: args["id"])
          raise ToolError, "No record #{describe(args)} in collection \"#{collection}\" of namespace \"#{store.namespace}\"." unless record

          record_json(record)
        end
      end

      private

      def describe(args)
        args["key"].present? ? "with key #{args['key'].to_s.inspect}" : "with id #{args['id']}"
      end
    end
  end
end
