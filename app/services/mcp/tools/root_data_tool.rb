# frozen_string_literal: true

module Mcp
  module Tools
    # What the six `root_data` tools share: the namespace, resolved from the
    # connection and never from an argument, and one rendering of a record.
    #
    # THE NAMESPACE IS NOT AN ARGUMENT, ON ANY OF THEM. It comes from the session
    # this MCP connection was written for (RuntimeConfigPostProcessor stamps
    # `session_id` onto the URL) through RootData::Namespace. That is a scoping
    # rule rather than an authorization one: the fleet shares one API key, and a
    # caller that composed its own `?session_id=` would reach that session's
    # root's namespace. Every write stamps `writing_session_id`, so what a
    # session wrote stays attributable either way. See docs/sessions/root-data.md.
    module RootDataTool
      private

      def store
        @store ||= RootData::Store.for(RootData::Namespace.for_session_id(context.self_session_id))
      end

      # Run the call, turning the store's refusals into tool errors the calling
      # agent can read and act on.
      def with_root_data
        yield
      rescue RootData::Namespace::Unresolvable, RootData::Store::Refused => e
        raise ToolError, e.message
      end

      def require_collection(args)
        require_arg(args, "collection").to_s
      end

      def record_json(record)
        {
          id: record.id,
          collection: record.collection,
          key: record.key,
          data: record.data,
          data_bytes: record.data_bytes,
          created_at: record.created_at&.iso8601,
          updated_at: record.updated_at&.iso8601,
          expires_at: record.expires_at&.iso8601,
          writing_session_id: record.writing_session_id
        }
      end
    end
  end
end
