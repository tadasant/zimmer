# frozen_string_literal: true

# A live conversation's scratchpad, edited by the person: add, change, remove
# and clear its notes (LiveConversations::Scratchpad). The conversation page
# shows the notes read-only and links here. After a write the page asks the
# call dock to send an open voice call a fresh `session.update`, so the call's
# instructions carry the notes as they are now.
class LiveScratchpadEntriesController < ApplicationController
  before_action :set_conversation

  def index
    @entries = @conversation.scratchpad_entries.to_a
  end

  def create
    write("Note added.") { scratchpad.add(params[:body]) }
  end

  def update
    write("Note saved.") { scratchpad.edit(params[:id], params[:body]) }
  end

  def destroy
    write("Note removed.") { scratchpad.remove(params[:id]) }
  end

  def clear
    write("Scratchpad cleared.") { scratchpad.clear }
  end

  private

  def set_conversation
    @conversation = LiveConversation.find(params[:live_conversation_id])
  end

  def scratchpad = LiveConversations::Scratchpad.new(@conversation, written_by: "person")

  def write(notice)
    yield
    # `saved`: the page tells the call dock, which refreshes an open call.
    redirect_to live_conversation_scratchpad_entries_path(@conversation, saved: 1), status: :see_other, notice: notice
  rescue LiveConversations::Scratchpad::Refused => e
    redirect_to live_conversation_scratchpad_entries_path(@conversation), status: :see_other, alert: e.message
  end
end
