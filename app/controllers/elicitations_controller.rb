# frozen_string_literal: true

# Web controller for user response to MCP server elicitation requests.
#
# When a user accepts or declines an elicitation from the session detail page,
# this controller resolves the elicitation and broadcasts the removal of the
# elicitation banner via Turbo Streams.
class ElicitationsController < ApplicationController
  # PATCH /elicitations/:id/respond
  def respond_to_elicitation
    @elicitation = Elicitation.find(params[:id])
    @session = @elicitation.session

    unless @elicitation.pending?
      redirect_to @session, alert: "This elicitation has already been resolved."
      return
    end

    action_type = params[:action_type]
    unless Elicitation::RESOLVE_ACTIONS.include?(action_type)
      redirect_to @session, alert: "Invalid action."
      return
    end

    content = parse_response_content

    @elicitation.resolve!(action: action_type, content: content)

    # Broadcast removal of the elicitation banner
    broadcast_elicitation_resolved(@session, @elicitation)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.remove("elicitation_#{@elicitation.id}")
      end
      format.html do
        redirect_to @session, notice: "Elicitation #{action_type}."
      end
    end
  end

  private

  def parse_response_content
    content = params[:content]
    return nil if content.blank?

    if content.is_a?(String)
      JSON.parse(content)
    else
      content.to_unsafe_h
    end
  rescue JSON::ParserError
    content
  end

  def broadcast_elicitation_resolved(session, elicitation)
    BroadcastService.new.remove_elicitation_banner(session, elicitation)
  rescue => e
    Rails.logger.error "[ElicitationsController] Failed to broadcast elicitation removal: #{e.message}"
  end
end
