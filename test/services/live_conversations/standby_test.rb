# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::StandbyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    stub_live_root
    stub_live_key
    @open = create_live_conversation(mode: "text", instructions: "# Live", instructions_source: "example/live@1")
  end

  test "prepares a conversation to start on, spoken, without touching the one that is open" do
    standby = nil
    assert_no_enqueued_jobs { standby = LiveConversations::Standby.prepare(client_surface: "carplay") }

    assert standby.standby?
    assert_not standby.open?
    assert standby.voice?
    assert_equal [ "# Live", "example/live@1", "carplay" ], standby.values_at(:instructions, :instructions_source, :client_surface)
    assert_equal @open, LiveConversation.current
    assert @open.reload.active?
  end

  test "asking again answers with the same row, brought up to date: one at most, however often an app asks" do
    first = LiveConversations::Standby.prepare(client_surface: "ios")
    @open.update!(instructions: "# Live, edited")

    again = nil
    assert_no_difference -> { LiveConversation.count } do
      3.times { again = LiveConversations::Standby.prepare(client_surface: "carplay") }
    end

    assert_equal first, again
    assert_equal [ "# Live, edited", "carplay" ], again.reload.values_at(:instructions, :client_surface)
    assert_raises(ActiveRecord::RecordNotUnique) { LiveConversation.create!(again.attributes.except("id")) }
  end

  test "it is on no list, is not one to go back to, and cannot be switched to" do
    standby = LiveConversations::Standby.prepare

    assert_not_includes LiveConversation.recent_first, standby
    assert_not_includes LiveConversation.to_go_back_to, standby
    assert_equal @open, LiveConversation.current
    assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Switch.call(standby.id) }
    assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Actions.new(standby).record_turn(role: "user", content: "hello") }
  end

  test "with nothing prepared to start from there is nothing to keep ready" do
    LiveConversation.delete_all

    refused = assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Standby.prepare }
    assert_equal :conflict, refused.status
    assert_nil LiveConversation.standby
  end

  test "Live Mode unavailable says why" do
    LiveConversations::Availability.any_instance.stubs(available?: false, reasons: [ "No key." ])

    assert_equal "No key.", assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Standby.prepare }.message
  end

  test "New takes it: it becomes the current conversation, starting now, and the open one ends" do
    standby = LiveConversations::Standby.prepare(client_surface: "ios")
    standby.update_columns(created_at: 2.hours.ago)

    started = nil
    assert_enqueued_with(job: LiveConversationPrepareJob, args: ->(args) { args == [ standby.id, { refresh: true } ] }) do
      started = LiveConversations::Start.call("voice", client_surface: "carplay", standby_id: standby.id)
    end

    assert_equal standby, started
    assert started.reload.active?
    assert started.voice?
    assert_equal "carplay", started.client_surface
    assert_in_delta Time.current, started.created_at, 5.seconds
    assert @open.reload.ended?
    assert_equal started, LiveConversation.current
    assert_includes LiveConversation.recent_first, started
    assert_nil LiveConversation.standby, "the next one is made when it is asked for"
  end

  test "asking again for one already taken answers with it, and ends and starts nothing" do
    standby = LiveConversations::Standby.prepare
    LiveConversations::Start.call("voice", standby_id: standby.id)

    again = nil
    assert_no_enqueued_jobs do
      assert_no_difference(-> { LiveConversation.count }) { again = LiveConversations::Start.call("voice", standby_id: standby.id) }
    end
    assert_equal standby, again
    assert again.active?
  end

  test "one that is gone is not missed: the conversation started is a new one" do
    standby = LiveConversations::Standby.prepare
    LiveConversations::Start.call("voice", standby_id: standby.id).end!

    [ standby.id, 999_999, "nonsense", "" ].each do |id|
      fresh = LiveConversations::Start.call("voice", standby_id: id)
      assert_not_equal standby, fresh, id.inspect
      assert fresh.active?
    end
  end

  test "a New without it leaves it ready for the next" do
    standby = LiveConversations::Standby.prepare

    LiveConversations::Start.call("text")

    assert_equal standby, LiveConversation.standby
  end
end
