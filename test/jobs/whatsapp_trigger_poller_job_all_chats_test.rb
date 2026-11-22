# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class WhatsappTriggerPollerJobAllChatsTest < ActiveJob::TestCase
  SELF = "15550000000@s.whatsapp.net"
  TADAS = "14842229088@s.whatsapp.net"
  TADAS_LID = "258303779192908@lid"
  GUEST = "15553334444@s.whatsapp.net"
  GROUP = "120363012345678901@g.us"

  # A bridge holding several chats. `aliases` maps a listed id to the chat it stands for, the way
  # the real bridge lists a person under both their `@lid` and their phone-number id and reads
  # either as the phone-number chat.
  class FakeBridge
    attr_accessor :chats, :aliases, :failing, :calls

    def initialize
      @chats = {}
      @aliases = {}
      @failing = []
      @calls = []
    end

    def ensure_ready!; end

    def list_chats(limit: 50, query: nil)
      listed = chats.keys.flat_map { |id| [ id, *aliases.select { |_alias, target| target == id }.keys ] }
      listed.map do |id|
        target = aliases.fetch(id, id)
        { "id" => id, "name" => target, "is_group" => target.end_with?("@g.us"),
          "last_message_at" => chats[target].map(&:timestamp).max }
      end.first(limit)
    end

    def get_messages(chat_id, after: nil, limit: 50)
      @calls << chat_id
      raise WhatsappService::Error, "boom" if failing.include?(chat_id)

      target = aliases.fetch(chat_id, chat_id)
      matching = chats.fetch(target, []).sort_by(&:timestamp).select { |m| after.nil? || m.timestamp >= after }
      WhatsappService::Page.new(chat_id: target, chat_name: "Chat #{target}", self_jid: SELF,
                                messages: matching.first(limit), has_more: matching.size > limit)
    end
  end

  setup do
    @bridge = FakeBridge.new
    WhatsappService.stubs(:configured?).returns(true)
    WhatsappService.stubs(:new).returns(@bridge)

    @trigger = Trigger.create!(
      name: "Zimmer's WhatsApp, every chat",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "New messages in {{channel|untrusted}} ({{chat_id}}):\n{{text|untrusted}}\nFrom: {{author|untrusted}}",
      trigger_conditions_attributes: [
        { condition_type: "whatsapp", configuration: { "chat_id" => "*", "mode" => "listen" } }
      ]
    )
    @condition = @trigger.trigger_conditions.first
  end

  def wa_message(id, chat, timestamp, text: "hello", sender: nil, **flags)
    WhatsappService::Message.new(
      id: id, chat_id: chat, timestamp: timestamp, sender_jid: sender || chat, sender_name: "Someone",
      from_me: flags.fetch(:from_me, false), sent_by_bridge: flags.fetch(:sent_by_bridge, false),
      text: text, type: "text", quoted_message_id: nil, mentions_self: false, reply_to_self: false
    )
  end

  def spawned_sessions
    Session.where("metadata->>'trigger_id' = ?", @trigger.id.to_s)
  end

  def baseline_at(timestamp)
    @condition.update_columns(last_message_ts: timestamp.to_s, configuration: @condition.configuration.merge("chats" => {}))
  end

  test "the first poll records the time and fires nothing, whatever the chats already hold" do
    @bridge.chats = { TADAS => [ wa_message("OLD", TADAS, Time.current.to_i - 30) ] }

    assert_no_difference -> { spawned_sessions.count } do
      WhatsappTriggerPollerJob.perform_now
    end

    assert_in_delta Time.current.to_i, @condition.reload.last_message_ts.to_i, 5
    assert_empty @bridge.calls
  end

  test "fires once per chat, and a chat first seen after the baseline fires on its first message" do
    baseline_at(1_000)
    @bridge.chats = {
      TADAS => [ wa_message("T0", TADAS, 900, text: "before"), wa_message("T1", TADAS, 1_010, text: "from tadas") ],
      GUEST => [ wa_message("G1", GUEST, 1_020, text: "what should I wear?") ]
    }

    assert_difference -> { spawned_sessions.count }, 2 do
      WhatsappTriggerPollerJob.perform_now
    end

    prompts = spawned_sessions.map(&:prompt)
    assert(prompts.any? { |p| p.include?("from tadas") && !p.include?("what should I wear") })
    assert(prompts.any? { |p| p.include?("what should I wear") && !p.include?("from tadas") })
    assert(prompts.none? { |p| p.include?("before") })
    assert_equal [ TADAS, GUEST ].sort, spawned_sessions.map { |s| s.metadata["whatsapp_chat_id"] }.sort

    assert_no_difference -> { spawned_sessions.count } do
      WhatsappTriggerPollerJob.perform_now
    end

    @bridge.chats[GUEST] << wa_message("G2", GUEST, 1_100, text: "thanks!")
    assert_difference -> { spawned_sessions.count }, 1 do
      WhatsappTriggerPollerJob.perform_now
    end
    assert_includes spawned_sessions.order(:id).last.prompt, "thanks!"
    assert_not_includes spawned_sessions.order(:id).last.prompt, "what should I wear"
  end

  test "a person listed under two ids is one chat and fires once" do
    baseline_at(1_000)
    @bridge.chats = { TADAS => [ wa_message("T1", TADAS, 1_010, text: "hi zimmer") ] }
    @bridge.aliases = { TADAS_LID => TADAS }

    assert_difference -> { spawned_sessions.count }, 1 do
      WhatsappTriggerPollerJob.perform_now
    end
    assert_equal TADAS, spawned_sessions.sole.metadata["whatsapp_chat_id"]

    assert_no_difference -> { spawned_sessions.count } do
      2.times { WhatsappTriggerPollerJob.perform_now }
    end

    state = @condition.reload.whatsapp_chat_states
    assert_equal [ TADAS ], state.keys
    assert_includes state[TADAS]["aliases"], TADAS_LID

    @bridge.chats[TADAS] << wa_message("T2", TADAS, 1_050, text: "again")
    assert_difference -> { spawned_sessions.count }, 1 do
      WhatsappTriggerPollerJob.perform_now
    end
  end

  test "Zimmer's own messages never fire" do
    baseline_at(1_000)
    @bridge.chats = { GUEST => [ wa_message("Z1", GUEST, 1_010, sender: SELF, from_me: true, sent_by_bridge: true) ] }

    assert_no_difference -> { spawned_sessions.count } do
      WhatsappTriggerPollerJob.perform_now
    end
  end

  test "one chat failing does not stop the others" do
    baseline_at(1_000)
    @bridge.chats = {
      GROUP => [ wa_message("P1", GROUP, 1_010, sender: GUEST) ],
      GUEST => [ wa_message("G1", GUEST, 1_020, text: "still heard") ]
    }
    @bridge.failing = [ GROUP ]
    ErrorReporter.expects(:report_exception).once

    assert_difference -> { spawned_sessions.count }, 1 do
      WhatsappTriggerPollerJob.perform_now
    end
    assert_includes spawned_sessions.sole.prompt, "still heard"
  end

  test "an all-chats trigger cannot reuse a session" do
    @trigger.reuse_session = true

    assert_not @trigger.valid?
    assert_includes @trigger.errors[:reuse_session].join, "all WhatsApp chats"
  end

  test "an all-chats trigger must fence what senders wrote" do
    @trigger.prompt_template = "Messages in {{channel}}: {{text|untrusted}}"

    assert_not @trigger.valid?
    assert_includes @trigger.errors[:prompt_template].join, "{{channel|untrusted}}"
  end

  test "describes itself as watching all chats" do
    assert_equal "WhatsApp: every message in all chats", @condition.description
  end
end
