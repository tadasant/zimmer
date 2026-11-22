# frozen_string_literal: true

module BoardCategories
  # Snooze or backlog a whole Your board v2 category — or put it back.
  #
  # Sessions::SetVisibility's own write and snooze-time rules (a naive wall-clock
  # time plus an IANA zone, never in the past), applied to the category row. The
  # category's sessions are not written: the category leaves the board as a
  # unit and comes back as one, and each session keeps whatever visibility it
  # had of its own. Presentation only, like every board visibility.
  class SetVisibility < Sessions::SetVisibility
    # @param category [BoardCategory]
    # @param visibility [String] "visible", "snoozed" or "backlogged"
    # @return [BoardCategory]
    # @raise [Sessions::SetVisibility::Error]
    def self.call(category:, visibility:, snoozed_until: nil, timezone: "UTC")
      new(session: category, visibility: visibility, snoozed_until: snoozed_until, timezone: timezone).call
    end

    private

    def allowed_visibilities
      BoardCategory::VISIBILITIES
    end
  end
end
