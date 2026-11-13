# frozen_string_literal: true

# A live conversation's scratchpad over the REST API — the iOS app's route to
# what the conversation page's Scratchpad edits (LiveConversations::Scratchpad).
#
#   GET    /api/v1/live_conversations/:id/scratchpad_entries            its notes, oldest first, and the limits
#   POST   /api/v1/live_conversations/:id/scratchpad_entries            add a note (body)
#   PATCH  /api/v1/live_conversations/:id/scratchpad_entries/:entry_id  change a note (body)
#   DELETE /api/v1/live_conversations/:id/scratchpad_entries/:entry_id  remove a note
#   DELETE /api/v1/live_conversations/:id/scratchpad_entries/clear      remove every note
#
# Every route, the read included, takes only the iOS app's sign-in acting as its
# person: the notes are the person's and their assistant's, and an API key — the
# fleet's — is not a person. A write answers with the pad as it now is; a voice
# call on the conversation picks the notes up from its next `session_update`.
class Api::V1::LiveScratchpadEntriesController < Api::BaseController
  accepts_native_app_tokens

  before_action :require_a_person_on_the_app
  before_action :set_conversation

  def index
    render json: pad_json
  end

  def create
    scratchpad.add(params[:body])
    render json: pad_json, status: :created
  end

  def update
    scratchpad.edit(params[:id], params[:body])
    render json: pad_json
  end

  def destroy
    scratchpad.remove(params[:id])
    render json: pad_json
  end

  def clear
    scratchpad.clear
    render json: pad_json
  end

  rescue_from LiveConversations::Scratchpad::Refused do |error|
    render_api_error("Unprocessable Entity", error.message, status: :unprocessable_entity)
  end

  private

  def set_conversation
    @conversation = LiveConversation.find_by(id: params[:live_conversation_id])
    render_api_error("Not Found", "Live conversation not found", status: :not_found) unless @conversation
  end

  def scratchpad = LiveConversations::Scratchpad.new(@conversation, written_by: "person")

  def pad_json
    {
      live_conversation_id: @conversation.id,
      entries: @conversation.scratchpad_entries.reload.map(&:as_api_json),
      max_entries: LiveConversations::Scratchpad::MAX_ENTRIES,
      max_entry_chars: LiveScratchpadEntry::MAX_BODY_CHARS
    }
  end
end
