# frozen_string_literal: true

# One live conversation's page, and the calls its page makes. Enable voice /
# Type instead post to `mode`; the browser's voice client
# (live_voice_controller.js) uses the JSON member routes to mint its Realtime
# secret, relay function calls, record transcript lines, and fetch a
# `session.update` when the Live settings change mid-call.
class LiveConversationsController < ApplicationController
  before_action :set_conversation, except: :create

  def show
    @turns = @conversation.turns.to_a
  end

  def create
    conversation = LiveConversations::Start.call(params[:mode].presence || "text", client_surface: "web")
    redirect_to live_conversation_path(conversation)
  rescue LiveConversations::Start::Unavailable => e
    redirect_to current_live_path(start: 1), alert: e.message
  rescue KeyError
    redirect_to live_path, alert: "Unknown live mode."
  end

  def mode
    actions.switch_mode(params[:mode].to_s)
    respond_to do |format|
      format.html { redirect_to live_conversation_path(@conversation) }
      format.json { render json: @conversation.as_api_json }
    end
  rescue LiveConversations::Actions::Refused => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: e.status }
      format.any { redirect_to live_conversation_path(@conversation), alert: e.message }
    end
  end

  def finish
    actions.finish
    respond_to do |format|
      format.html { redirect_to live_conversation_path(@conversation), notice: "Conversation ended." }
      format.json { render json: @conversation.as_api_json }
    end
  end

  def messages
    actions.post_message(params[:content])
    respond_to do |format|
      format.html { redirect_to live_conversation_path(@conversation) }
      format.turbo_stream { head :no_content }
      format.json { head :created }
    end
  rescue LiveConversations::Actions::Refused => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: e.status }
      # A Turbo form submit lands here too, and shows a redirect's flash.
      format.any { redirect_to live_conversation_path(@conversation), alert: e.message }
    end
  end

  def client_secret
    render json: actions.client_secret
  rescue LiveConversations::Actions::Refused => e
    render json: { error: e.message }, status: e.status
  end

  def tool_calls
    render json: actions.tool_call(name: params[:name].to_s, arguments: params[:arguments], call_id: params[:call_id].to_s)
  rescue LiveConversations::Actions::Refused => e
    render json: { error: e.message }, status: e.status
  end

  # Voice: the `session.update` that brings the open call up to the current
  # Live settings and guidance, which the dock sends after they changed.
  def session_update
    render json: { session: actions.session_update }
  rescue LiveConversations::Actions::Refused => e
    render json: { error: e.message }, status: e.status
  end

  def turns
    heard = actions.record_turn(role: params[:role], content: params[:content])
    render json: heard.as_api_json, status: heard.turn ? :created : :ok
  rescue LiveConversations::Actions::Refused => e
    render json: { error: e.message }, status: e.status
  end

  private

  def set_conversation
    @conversation = LiveConversation.find(params[:id])
  end

  # `listening_modes`: the dock asks for each reply itself when Listening is gated.
  def actions = LiveConversations::Actions.new(@conversation, client_surface: "web", listening_modes: params[:listening_modes].present?)
end
