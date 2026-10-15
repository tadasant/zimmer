# frozen_string_literal: true

# Live Mode and Live Voice over the REST API — the iOS app's route to the same
# conversations the web page shows, with the same rules (LiveConversations::Actions).
#
#   GET  /api/v1/live                              both modes: available? why not?
#   GET  /api/v1/live_conversations                recent conversations (?mode=)
#   POST /api/v1/live_conversations                start one (mode=text|voice); ends the mode's open one
#   GET  /api/v1/live_conversations/:id            one conversation with its turns (?after_turn_id= for new ones)
#   POST /api/v1/live_conversations/:id/finish     end it
#   POST /api/v1/live_conversations/:id/messages   Live Mode: a typed message (content)
#   POST /api/v1/live_conversations/:id/client_secret  Live Voice: mint a Realtime client secret
#   POST /api/v1/live_conversations/:id/tool_calls     Live Voice: run a function call (name, arguments, call_id)
#   POST /api/v1/live_conversations/:id/turns          Live Voice: record a transcript line (role, content)
class Api::V1::LiveConversationsController < Api::BaseController
  accepts_native_app_tokens

  INDEX_LIMIT = 20

  before_action :set_conversation, except: %i[modes index create]

  def modes
    render json: { modes: LiveConversations.mode_keys.map { |key| LiveConversations::Availability.for(key).as_api_json } }
  end

  def index
    scope = LiveConversation.recent_first.limit(INDEX_LIMIT)
    scope = scope.for_mode(params[:mode]) if params[:mode].present?
    render json: {
      live_conversations: scope.map(&:as_api_json),
      current: LiveConversations.mode_keys.index_with { |key| LiveConversation.current(key)&.id }
    }
  end

  def show
    json = @conversation.as_api_json
    turns = @conversation.turns
    turns = turns.where("id > ?", params[:after_turn_id].to_i) if params[:after_turn_id].present?
    json[:turns] = turns.map(&:as_api_json)
    render json: json
  end

  def create
    mode = params[:mode].to_s
    unless LiveConversations.mode_keys.include?(mode)
      return render_api_error("Unprocessable Entity", "mode must be one of: #{LiveConversations.mode_keys.join(', ')}", status: :unprocessable_entity)
    end

    conversation = LiveConversations::Start.call(mode)
    render json: conversation.as_api_json, status: :created
  rescue LiveConversations::Start::Unavailable => e
    render_api_error("Service Unavailable", e.message, status: :service_unavailable)
  end

  def finish
    render json: actions.finish.as_api_json
  end

  def messages
    turn = actions.post_message(params[:content])
    render json: turn.as_api_json, status: :created
  end

  def client_secret
    render json: actions.client_secret
  end

  def tool_calls
    render json: actions.tool_call(name: params[:name].to_s, arguments: params[:arguments], call_id: params[:call_id].to_s)
  end

  def turns
    render json: actions.record_turn(role: params[:role], content: params[:content]).as_api_json, status: :created
  end

  rescue_from LiveConversations::Actions::Refused do |error|
    render_api_error(Rack::Utils::HTTP_STATUS_CODES[Rack::Utils.status_code(error.status)], error.message, status: error.status)
  end

  private

  def set_conversation
    @conversation = LiveConversation.find_by(id: params[:id])
    render_api_error("Not Found", "Live conversation not found", status: :not_found) unless @conversation
  end

  def actions = LiveConversations::Actions.new(@conversation)
end
