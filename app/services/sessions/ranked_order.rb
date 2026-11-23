# frozen_string_literal: true

module Sessions
  # The order the spot queue is worked in, with the priority sessions that
  # outrank all of it stacked above: `GET /api/v1/sessions?view=ranked`, which
  # is how the iOS app draws its Ranked view.
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
  class RankedOrder
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
