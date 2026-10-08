# frozen_string_literal: true

require "test_helper"

class TriggerConditionEmailTest < ActiveSupport::TestCase
  FENCED = "{{text|untrusted}}\nFrom {{author|untrusted}}: {{title|untrusted}} ({{message_id}}, {{thread_id}}) {{link}}"

  def build_trigger(template: FENCED, configuration: { "query" => "in:inbox" })
    Trigger.new(
      name: "Inbox", status: "enabled", agent_root_name: "zimmer", prompt_template: template,
      trigger_conditions_attributes: [ { condition_type: "email", configuration: configuration } ]
    )
  end

  test "a blank query watches the inbox, and automated mail is off unless asked for" do
    condition = TriggerCondition.new(condition_type: "email", configuration: { "query" => "  " })
    assert_equal "in:inbox", condition.email_query
    assert_not condition.email_include_automated?

    condition.configuration = { "query" => "to:zimmer+bugs@example.com", "include_automated" => "1" }
    assert_equal "to:zimmer+bugs@example.com", condition.email_query
    assert condition.email_include_automated?
    assert_equal "Email: new mail matching to:zimmer+bugs@example.com, automated mail included", condition.description
  end

  test "the query is one short line" do
    assert build_trigger.valid?
    assert_not build_trigger(configuration: { "query" => "in:inbox\nfrom:x" }).valid?
    assert_not build_trigger(configuration: { "query" => "a" * 501 }).valid?
  end

  test "a template that writes what the sender wrote bare is refused" do
    trigger = build_trigger(template: "New mail: {{text}} from {{author}} about {{title|untrusted}}")

    assert_not trigger.valid?
    message = trigger.errors[:prompt_template].join
    assert_includes message, "{{text|untrusted}}, {{author|untrusted}}"
    assert_not_includes message, "{{title}}"
  end

  test "the fence rule is the email condition's, not every trigger's" do
    trigger = build_trigger(template: "Slack says {{text}}")
    trigger.trigger_conditions.first.assign_attributes(condition_type: "slack", configuration: { "event_type" => "bot_mention" })
    assert trigger.valid?, trigger.errors.full_messages.to_sentence
  end

  test "trusted identifiers render only in Gmail's id shape" do
    trigger = build_trigger
    prompt = trigger.interpolate_prompt(text: "hi", message_id: "18c0aa", thread_id: "not an id; rm -rf")

    assert_includes prompt, "(18c0aa, )"
  end

  test "a save keeps the poller's state, and a change of search re-baselines" do
    trigger = build_trigger
    trigger.save!
    condition = trigger.trigger_conditions.first
    condition.update_columns(last_message_ts: "1700000000", configuration: condition.configuration.merge("seen_messages" => { "a1" => 1_700_000_000 }))

    # The form submits only its own fields.
    condition.reload.update!(configuration: { "query" => "in:inbox", "include_automated" => "0" })
    assert_equal({ "a1" => 1_700_000_000 }, condition.reload.email_seen_messages)
    assert_equal "1700000000", condition.last_message_ts

    condition.update!(configuration: { "query" => "in:inbox", "include_automated" => "1" })
    assert_nil condition.reload.last_message_ts
    assert_empty condition.email_seen_messages

    condition.update_columns(last_message_ts: "1700000000")
    condition.reload.update!(configuration: { "query" => "label:zimmer", "include_automated" => "1" })
    assert_nil condition.reload.last_message_ts
  end
end
