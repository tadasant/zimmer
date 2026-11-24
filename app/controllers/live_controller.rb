# frozen_string_literal: true

# /live — Live Mode. The overview says whether the OpenAI key is set and where
# to set it (Zimmer never writes it — see SecretPresence), and /live/current
# resumes the current conversation or offers to start one.
class LiveController < ApplicationController
  RECENT_LIMIT = 10

  def index
    @availability = LiveConversations::Availability.current
    @current = LiveConversation.current
    @key_status = SecretPresence.for(OpenaiClient::API_KEY_VARIABLE)
    @recent = LiveConversation.recent_first.limit(RECENT_LIMIT)
  end

  def show
    # What the call dock polls, to follow a switch made somewhere else and to
    # hear that something came back from the background.
    return render(json: current_call) if request.format.json?

    @availability = LiveConversations::Availability.current
    current = LiveConversation.current
    return redirect_to(live_conversation_path(current)) if current && params[:start].blank?

    @recent = LiveConversation.recent_first.limit(RECENT_LIMIT)
  end

  private

  def current_call
    current = LiveConversation.current
    {
      current_id: current&.id,
      voice: current&.voice?,
      background_results: current ? LiveConversations::BackgroundResults.waiting_count(current, call: params[:call].presence) : 0
    }
  end
end
