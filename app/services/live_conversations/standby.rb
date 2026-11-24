# frozen_string_literal: true

module LiveConversations
  # A conversation kept ready for the person's next New, so the tap that starts
  # it waits on nothing: the iOS app opens its voice connection on this one ahead
  # of the tap (Actions#client_secret and #gpt_live_session, `prewarm`), and the
  # tap makes it the current conversation (Start, `standby_id`).
  #
  # Until then it is nobody's conversation. It is not open, so it is never the
  # current one, takes no message or turn, and ends nothing; and it is on no list
  # (LiveConversation.recent_first). There is at most one: asking again answers
  # with the same row, brought up to the instructions and tool lists a new
  # conversation would start on now. So an app that asks all day and never taps
  # New leaves one unused row, not a pile of them.
  #
  # Only where a new conversation could start `active`: with no prepared
  # conversation to seed it from there is nothing to connect on yet, and the
  # first New on a root prepares as it always has.
  class Standby
    def self.prepare(client_surface: nil)
      availability = Availability.current
      raise Actions::Refused.new(availability.reasons.join(" "), status: :service_unavailable) unless availability.available?

      seed = Start.seed(availability.root)
      raise Actions::Refused.new("There is no earlier conversation to prepare a new one from yet.", status: :conflict) if seed.nil?

      mode = LiveConversations.mode("voice")
      attributes = seed.attributes.merge(
        mode: mode.key, model: mode.model, agent_root: availability.root.name, status: LiveConversation::STANDBY,
        client_surface: LiveConversation.normalize_client_surface(client_surface), last_activity_at: Time.current
      )
      existing = LiveConversation.standby
      # A tap can take it between the read and this: `with_lock` looks again.
      return existing if existing&.with_lock { existing.standby? && existing.update!(attributes) }

      LiveConversation.create!(attributes)
    rescue ActiveRecord::RecordNotUnique
      # Another request made it first.
      LiveConversation.standby || raise
    end
  end
end
