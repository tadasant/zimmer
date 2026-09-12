# frozen_string_literal: true

module Sessions
  # The dashboard's User view, as an ordering rule two surfaces share.
  #
  # The web view (SessionsController#index) and the `get_user_view` MCP tool must
  # agree about what "the board, top to bottom" means, because the reprioritizing
  # session reads the board over MCP and writes an order the human then reads in
  # the browser. If the two disagreed, the agent would be reordering a list nobody
  # is looking at.
  #
  # == The order
  #
  #   1. priority sessions above spot ones
  #   2. within each, precedence descending
  #   3. within each, oldest first
  #
  # (2) and (3) are `Session.ranked`, the spot queue's own order. (1) is the part
  # that cannot be an ORDER BY: the scheduling class is not a column. A session's
  # class is whatever `scheduling_class` it named, else the default for its
  # genesis, resolved live against AppSetting — which is what `priority_classified`
  # spells out in SQL. So the two halves are queried separately and concatenated,
  # which also gives the limit somewhere sensible to apply.
  #
  # The list is deliberately NOT rendered as two sections. Splitting it is what the
  # Ranked view does, and the User view is the screen you work top to bottom: one
  # list, with a per-row badge saying which class each session is.
  class UserView
    # The ordered rows, capped.
    #
    # @param scope [ActiveRecord::Relation] sessions already narrowed by whatever
    #   filters the caller applies (status, board visibility, search, ...)
    # @param limit [Integer] hard cap on the number of rows returned, across both
    #   halves together
    # @return [Array<Session>]
    def self.rows(scope:, limit:)
      priority = scope.priority_classified(SessionGenesis::PRIORITY).ranked.limit(limit).to_a
      return priority if priority.size >= limit

      priority + scope.priority_classified(SessionGenesis::SPOT).ranked.limit(limit - priority.size).to_a
    end
  end
end
