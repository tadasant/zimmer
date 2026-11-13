# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::ScratchpadTest < ActiveSupport::TestCase
  setup do
    @conversation = create_live_conversation
    @pad = LiveConversations::Scratchpad.new(@conversation, written_by: "assistant")
  end

  test "add, edit, remove and clear, each on this conversation's pad only" do
    other = create_live_conversation(status: LiveConversation::ENDED)
    foreign = other.scratchpad_entries.create!(body: "someone else's note", written_by: "assistant")

    note = @pad.add("Session 1234 can't merge yet; don't raise it")
    assert_equal "assistant", note.written_by
    assert_match(/note #{note.id}, you, .*\) Session 1234 can't merge yet/, @pad.listing)

    LiveConversations::Scratchpad.new(@conversation, written_by: "person").edit(note.id, "Session 1234 is merged")
    assert_equal [ "Session 1234 is merged" ], @conversation.scratchpad_entries.reload.map(&:body)
    assert_equal "person", note.reload.written_by

    error = assert_raises(LiveConversations::Scratchpad::Refused) { @pad.remove(foreign.id) }
    assert_match(/no note #{foreign.id}/, error.message)
    assert_raises(LiveConversations::Scratchpad::Refused) { @pad.edit(foreign.id, "hijacked") }
    assert_equal "someone else's note", foreign.reload.body

    @pad.remove(note.id)
    assert_equal "The scratchpad is empty (0 of #{LiveConversations::Scratchpad::MAX_ENTRIES} notes).", @pad.listing

    2.times { |i| @pad.add("note #{i}") }
    assert_equal 2, @pad.clear
    assert_equal 1, other.scratchpad_entries.count
  end

  test "saving a note unchanged leaves its writer and time alone, and broadcasts nothing" do
    note = @pad.add("unchanged")
    BroadcastService.any_instance.expects(:broadcast_partial).never
    LiveConversations::Scratchpad.new(@conversation, written_by: "person").edit(note.id, " unchanged ")

    assert_equal "assistant", note.reload.written_by
  end

  test "a write past either limit is refused and says so, never cut" do
    long = "x" * (LiveScratchpadEntry::MAX_BODY_CHARS + 1)
    error = assert_raises(LiveConversations::Scratchpad::Refused) { @pad.add(long) }
    assert_match(/at most #{LiveScratchpadEntry::MAX_BODY_CHARS} characters; this one is #{long.length}/, error.message)
    assert_raises(LiveConversations::Scratchpad::Refused) { @pad.add("  ") }

    LiveConversations::Scratchpad::MAX_ENTRIES.times { |i| @pad.add("note #{i}") }
    error = assert_raises(LiveConversations::Scratchpad::Refused) { @pad.add("one more") }
    assert_match(/full \(#{LiveConversations::Scratchpad::MAX_ENTRIES} notes\)/, error.message)
    assert_equal LiveConversations::Scratchpad::MAX_ENTRIES, @conversation.scratchpad_entries.count
  end

  test "a write broadcasts the conversation page's panel" do
    BroadcastService.any_instance.expects(:broadcast_partial).with(has_entries(stream: @conversation.stream_name, target: @conversation.scratchpad_dom_id, partial: "live_conversations/scratchpad"))
    @pad.add("note")
  end
end
