# frozen_string_literal: true

module BoardCategories
  # Tell every open Your board that the set of categories, their names or their
  # order changed, so it fetches the board again and reconciles.
  #
  # A signal rather than the new layout: which sessions each group holds depends
  # on the filters of the page that is listening, and a deleted category moves its
  # sessions by a foreign key, with no session write to announce them.
  #
  # Collapsing is not announced. It is stored on the category for the next load,
  # and folding a section shut on another screen would take it from its reader.
  class AnnounceLayoutChange
    TARGET = "board_v2_signals"

    def self.call
      BroadcastService.new(error_context: { source: name }).broadcast_html(
        action: :append, stream: Session::SESSIONS_INDEX_STREAM, target: TARGET
      ) { '<div data-board-v2-target="signal" hidden></div>'.html_safe }
    end
  end
end
