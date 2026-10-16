# frozen_string_literal: true

# /live — the two live modes. The overview says whether the OpenAI key is set and
# where to set it (Zimmer never writes it — see SecretPresence), and /live/:mode
# resumes the mode's current conversation or offers to start one.
class LiveController < ApplicationController
  RECENT_LIMIT = 10

  def index
    @availabilities = LiveConversations.mode_keys.map { |key| LiveConversations::Availability.for(key) }
    @key_status = SecretPresence.for(OpenaiClient::API_KEY_VARIABLE)
    @recent = LiveConversation.recent_first.limit(RECENT_LIMIT)
  end

  def show
    return redirect_to(live_path, alert: "Unknown live mode.") unless LiveConversations.mode_keys.include?(params[:mode])

    @availability = LiveConversations::Availability.for(params[:mode])
    current = LiveConversation.current(params[:mode])
    return redirect_to(live_conversation_path(current)) if current && params[:start].blank?

    @recent = LiveConversation.for_mode(params[:mode]).recent_first.limit(RECENT_LIMIT)
  end
end
