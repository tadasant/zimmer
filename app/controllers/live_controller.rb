# frozen_string_literal: true

# /live — the two live modes. The overview carries the OpenAI key (write and
# delete only, like the Pi tab's OpenRouter key: nothing here reads it back),
# and /live/:mode resumes the mode's current conversation or offers to start one.
class LiveController < ApplicationController
  RECENT_LIMIT = 10

  def index
    @availabilities = LiveConversations.mode_keys.map { |key| LiveConversations::Availability.for(key) }
    @key_status = ManagedSecret.live_openai_key.status
    @recent = LiveConversation.recent_first.limit(RECENT_LIMIT)
  end

  def show
    @availability = LiveConversations::Availability.for(params[:mode])
    current = LiveConversation.current(params[:mode])
    return redirect_to(live_conversation_path(current)) if current && params[:start].blank?

    @recent = LiveConversation.for_mode(params[:mode]).recent_first.limit(RECENT_LIMIT)
  end

  # The value goes from params to ManagedSecret and nowhere else — not the
  # flash, not the log (`_key` is filtered), not the response.
  def update_openai_key
    result = ManagedSecret.live_openai_key.write(params[:live_openai_api_key].to_s)
    redirect_to live_path, **flash_for(result)
  end

  def destroy_openai_key
    result = ManagedSecret.live_openai_key.delete
    redirect_to live_path, **flash_for(result)
  end

  private

  def flash_for(result)
    message = [ result.message, result.detail ].compact.join(" ")
    result.ok? ? { notice: message } : { alert: message }
  end
end
