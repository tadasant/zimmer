# frozen_string_literal: true

module Sessions
  # Your board (`/?view=board_v2`): the sessions the board's filters match,
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
  # snoozed or backlogged category are excluded from that query and only
  # their ids read, so a large parked category never crowds the live ones out.
  class BoardV2
    Section = Struct.new(:category, :sessions, keyword_init: true)
    # `session_ids`, not only their number: an open board is told about sessions
    # one at a time, and to keep the count true it has to know which of them it
    # has already counted.
    TuckedSection = Struct.new(:category, :session_ids, keyword_init: true) do
      def count
        session_ids.size
      end
    end
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

      # `transcript` is dropped: a legacy JSON column on `sessions` (transcripts
      # live in session_transcript_chunks) that nothing on a card reads, and
      # this reads up to `limit` rows.
      fetched = shown_scope
        .select(Session.column_names - [ "transcript" ])
        .reorder(Session::LAST_TOUCHED_ORDER, id: :desc)
        .limit(limit + 1)
        .to_a
      truncated = fetched.size > limit
      grouped = fetched.first(limit).group_by(&:board_category_id)

      tucked_sessions = Hash.new { |hash, key| hash[key] = [] }
      if tucked_ids.any?
        scope.where(board_category_id: tucked_ids).reorder(nil).pluck("sessions.board_category_id", "sessions.id")
          .each { |category_id, id| tucked_sessions[category_id] << id }
      end

      Result.new(
        uncategorized: grouped.fetch(nil, []),
        sections: showing.map { |category| Section.new(category: category, sessions: grouped.fetch(category.id, [])) },
        tucked: tucked.map { |category| TuckedSection.new(category: category, session_ids: tucked_sessions[category.id]) },
        truncated: truncated
      )
    end
  end
end
