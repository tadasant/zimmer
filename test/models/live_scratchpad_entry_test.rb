# frozen_string_literal: true

require "test_helper"

class LiveScratchpadEntryTest < ActiveSupport::TestCase
  setup do
    @conversation = create_live_conversation
  end

  test "a note is squished, bounded, and says who wrote it" do
    entry = @conversation.scratchpad_entries.create!(body: "  Session 1234\n can't merge yet  ", written_by: "assistant")
    assert_equal "Session 1234 can't merge yet", entry.body
    assert_equal "Live Mode", entry.writer_label

    assert_not @conversation.scratchpad_entries.new(body: "x" * (LiveScratchpadEntry::MAX_BODY_CHARS + 1), written_by: "person").valid?
    assert_not @conversation.scratchpad_entries.new(body: "   ", written_by: "person").valid?
    assert_not @conversation.scratchpad_entries.new(body: "ok", written_by: "someone").valid?
  end

  test "the notes go with their conversation" do
    @conversation.scratchpad_entries.create!(body: "note", written_by: "person")
    assert_difference -> { LiveScratchpadEntry.count }, -1 do
      @conversation.destroy!
    end
  end
end
