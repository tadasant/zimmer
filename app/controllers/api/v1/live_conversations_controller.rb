# frozen_string_literal: true

# Live Mode over the REST API — the iOS app's route to the same conversations
# the web page shows, with the same rules (LiveConversations::Actions).
#
#   GET  /api/v1/live                              available? why not? each mode's model
#   GET  /api/v1/live_conversations                recent conversations, and the current one
#   POST /api/v1/live_conversations                start one (mode=text|voice, default text); ends the open one
#   GET  /api/v1/live_conversations/:id            one conversation with its turns (?after_turn_id= for new ones)
#   GET  /api/v1/live_conversations/:id/sessions   the sessions its tool calls have touched, newest first, with board rows
#   POST /api/v1/live_conversations/:id/finish     end it
#   POST /api/v1/live_conversations/:id/mode       switch typed ⇄ spoken (mode=text|voice)
#   POST /api/v1/live_conversations/:id/messages   typed: a message (content)
#   POST /api/v1/live_conversations/:id/client_secret  voice: mint a Realtime client secret
#   POST /api/v1/live_conversations/:id/tool_calls     voice: run a function call (name, arguments, call_id)
#   POST /api/v1/live_conversations/:id/turns          voice: record a transcript line (role, content) → respond?
#   POST /api/v1/live_conversations/:id/session_update voice: the `session.update` for the current Live settings
#
# The Live settings themselves are Api::V1::LiveSettingsController's.
#
# The reads take an API key. Everything that starts, steers or speaks for a
# conversation takes only the iOS app's sign-in, on a grant that acts as its
# person: a live model can enable any catalog MCP server, and `tool_calls` runs
# one directly, so an API key — the fleet's — must not reach through here to the
# whole catalog. The web page is the other way in, behind the sign-in wall.
class Api::V1::LiveConversationsController < Api::BaseController
  include ApiSessionSerialization

  accepts_native_app_tokens

  INDEX_LIMIT = 20
  PERSON_ACTIONS = %i[create finish mode messages client_secret tool_calls turns session_update].freeze

  before_action :require_a_person_on_the_app, only: PERSON_ACTIONS
  before_action :set_conversation, except: %i[modes index create]

  def modes
    render json: LiveConversations::Availability.current.as_api_json
  end

  # `current` is keyed by the mode the open conversation is in right now, so a
  # client reading it per mode finds it under one of them; `current_id` is the
  # same conversation without the key.
  def index
    current = LiveConversation.current
    render json: {
      live_conversations: LiveConversation.recent_first.limit(INDEX_LIMIT).map(&:as_api_json),
      current_id: current&.id,
      current: current ? { current.mode => current.id } : {}
    }
  end

  def show
    json = @conversation.as_api_json
    turns = @conversation.turns
    turns = turns.where("id > ?", params[:after_turn_id].to_i) if params[:after_turn_id].present?
    json[:turns] = turns.map(&:as_api_json)
    render json: json
  end

  # The sessions the conversation has started, checked on or followed up, the
  # most recently named first, each with its board row (agent root, status
  # summary) as `GET /sessions?include=board_row` gives it. A read, like show.
  def sessions
    ids = @conversation.referenced_session_ids
    by_id = Session.where(id: ids).includes(:status_summary).index_by(&:id)
    sessions = ids.filter_map { |id| by_id[id] }
    render json: {
      sessions: sessions.map { |session| session_json(session) },
      board_rows: sessions.to_h { |session| [ session.id.to_s, { agent_root: session.agent_root_key, status_summary: session_status_summary_json(session) } ] }
    }
  end

  def create
    mode = params[:mode].presence || "text"
    unless LiveConversations.mode_keys.include?(mode.to_s)
      return render_api_error("Unprocessable Entity", "mode must be one of: #{LiveConversations.mode_keys.join(', ')}", status: :unprocessable_entity)
    end

    conversation = LiveConversations::Start.call(mode, client_surface: api_turn_source.surface)
    render json: conversation.as_api_json, status: :created
  rescue LiveConversations::Start::Unavailable => e
    render_api_error("Service Unavailable", e.message, status: :service_unavailable)
  end

  def finish
    render json: actions.finish.as_api_json
  end

  def mode
    render json: actions.switch_mode(params[:mode].to_s).as_api_json
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

  def session_update
    render json: { session: actions.session_update }
  end

  def turns
    heard = actions.record_turn(role: params[:role], content: params[:content])
    render json: heard.as_api_json, status: heard.turn ? :created : :ok
  end

  rescue_from LiveConversations::Actions::Refused do |error|
    render_api_error(Rack::Utils::HTTP_STATUS_CODES[Rack::Utils.status_code(error.status)], error.message, status: error.status)
  end

  private

  def set_conversation
    @conversation = LiveConversation.find_by(id: params[:id])
    render_api_error("Not Found", "Live conversation not found", status: :not_found) unless @conversation
  end

  # `listening_modes`: the client asks for each reply itself when Listening is
  # gated (LiveConversations::Listening); an app from before that is answered as
  # `always`.
  def actions = LiveConversations::Actions.new(@conversation, client_surface: api_turn_source.surface, listening_modes: params[:listening_modes].present?)
end
