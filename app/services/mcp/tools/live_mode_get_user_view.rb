# frozen_string_literal: true

module Mcp
  module Tools
    # get_user_view as the Live Mode assistant gets it (the `live_mode` tool
    # group): what needs the person, most recently touched first, in one call.
    #
    # The same rows and the same dropped-row line as GetUserView. It differs in
    # three ways: `order` defaults to `last_touched`, the narrowing arguments a
    # voice conversation has no use for (priority class, agent root, visibility,
    # summary length) are gone, and the description is short.
    class LiveModeGetUserView < GetUserView
      tool_name "get_user_view"

      ACCEPTED_ARGUMENTS = %w[status carplay_fit order page per_page].freeze

      description <<~DESC
        What needs the person, most recently touched first, in one call; with carplay_fit it also says how many rows it left out and what kind.

        Defaults to sessions in `needs_input`, the ones waiting on them. Each row has the title, status, when it was
        last touched, its PR and CI, and a short generated status. From a car pass `carplay_fit: "not_laptop_only"`
        to drop the rows that need a screen. The answer then says how many it left out and what kind ("9 laptop-only
        (4 a credential, …)"): say that, because a filtered read is not the whole board. `order: "board"` is the
        dashboard's own order, for when the person asks for it.
      DESC

      input_schema({
        type: "object",
        properties: {
          status: {
            oneOf: [
              { type: "string", enum: SessionsController::STATUS_FILTER_OPTIONS },
              { type: "array", items: { type: "string", enum: SessionsController::STATUS_FILTER_OPTIONS } }
            ],
            description: 'Statuses to include. Default ["needs_input"]; an empty array is every status.'
          },
          carplay_fit: {
            type: "string",
            enum: SessionCarplayFit::FILTER_OPTIONS,
            description: '"not_laptop_only" drops the rows that need a screen or keyboard. The answer says how many it dropped and what kind.'
          },
          order: {
            type: "string",
            enum: ORDERS,
            description: '"last_touched" (default): what the person was last on, first. "board": the dashboard\'s own order.'
          },
          page: { type: "number", minimum: 1, description: "Page number. Default: 1" },
          per_page: {
            type: "number", minimum: 1, maximum: MAX_PER_PAGE,
            description: "Rows per page. Default: #{DEFAULT_PER_PAGE}."
          }
        },
        required: []
      })

      def call(args)
        narrowed = args.slice(*ACCEPTED_ARGUMENTS)
        narrowed["order"] = ORDER_LAST_TOUCHED if narrowed["order"].blank?
        super(narrowed)
      end

      private

      def footer(_order)
        "*That is every matching row.*"
      end
    end
  end
end
