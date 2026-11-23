# frozen_string_literal: true

module BoardCategories
  # Put a session in a Your board category, or take it out (nil).
  #
  # The only writer of `sessions.board_category_id`, so the web UI's drag and the
  # MCP tool agree. A person's decision, never inferred: nothing in Zimmer calls
  # this on its own. It writes one column with `update_columns`, so it does not
  # touch `updated_at` and does not count as the session being "touched" — moving
  # a card does not reshuffle the category it lands in.
  class Assign
    class Error < StandardError; end

    # @param session [Session]
    # @param category_id [Integer, String, nil] nil or blank for Uncategorized
    # @return [BoardCategory, nil] the category the session is now in
    def self.call(session:, category_id:)
      category =
        if category_id.blank?
          nil
        else
          BoardCategory.find_by(id: category_id) || raise(Error, "No board category with id #{category_id}.")
        end

      session.update_columns(board_category_id: category&.id)
      category
    end
  end
end
