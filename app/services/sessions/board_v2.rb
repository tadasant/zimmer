# frozen_string_literal: true

module Sessions
  # Your board v2 (`/?view=board_v2`): the sessions the board's filters match,
  # grouped into the operator's own categories.
  #
  # == The layout
  #
  #   * Uncategorized first — where every new session lands, so it is the inbox
  #     a person sorts from.
  #   * Then each category in `position` order.
  #   * Then, at the bottom, every snoozed or backlogged category as a header
  #     with a count and no rows.
  #
  # == The order inside a group
  #
  # Most recently touched first: Session::LAST_TOUCHED_ORDER, the same rule as
  # the dashboard's Last Touched view and `get_user_view`'s `order: "last_touched"`.
  # "Touched" is the last time a person opened, messaged or acted on the session
  # (`metadata.last_user_activity_at`), falling back to when it was created. Not
  # `updated_at`, which every heartbeat, transcript append and status write bumps:
  # sorting by it would order the board by which agent was chattiest.
  #
  # == The cap
  #
  # One query for every visible group together, capped at `limit` rows and
  # ordered by last touched, so when the board is truncated it is the least
  # recently touched sessions that drop off, wherever they sit. Sessions in a
  # snoozed or backlogged category are excluded from that query and counted
  # separately, so a large parked category never crowds the live ones out.
  class BoardV2
    Section = Struct.new(:category, :sessions, keyword_init: true)
    TuckedSection = Struct.new(:category, :count, keyword_init: true)
    Result = Struct.new(:uncategorized, :sections, :tucked, :truncated, keyword_init: true) do
      def session_count
        uncategorized.size + sections.sum { |section| section.sessions.size }
      end
    end

    # @param scope [ActiveRecord::Relation<Session>] already narrowed by the
    #   board's filters; no select or includes applied
    # @param limit [Integer]
    # @return [Result]
    def self.build(scope:, limit:)
      categories = BoardCategory.ordered.to_a
      now = Time.current
      showing, tucked = categories.partition { |category| category.board_visible?(now) }
      tucked_ids = tucked.map(&:id)

      shown_scope = scope
      if tucked_ids.any?
        shown_scope = shown_scope.where(
          "sessions.board_category_id IS NULL OR sessions.board_category_id NOT IN (?)", tucked_ids
        )
      end

      # `transcript` is dropped for the reason SessionsController gives for the
      # User view: a legacy column nothing on a card reads.
      fetched = shown_scope
        .select(Session.column_names - [ "transcript" ])
        .reorder(Session::LAST_TOUCHED_ORDER, id: :desc)
        .limit(limit + 1)
        .to_a
      truncated = fetched.size > limit
      grouped = fetched.first(limit).group_by(&:board_category_id)

      tucked_counts = tucked_ids.any? ? scope.where(board_category_id: tucked_ids).group(:board_category_id).count : {}

      Result.new(
        uncategorized: grouped.fetch(nil, []),
        sections: showing.map { |category| Section.new(category: category, sessions: grouped.fetch(category.id, [])) },
        tucked: tucked.map { |category| TuckedSection.new(category: category, count: tucked_counts.fetch(category.id, 0)) },
        truncated: truncated
      )
    end
  end
end
