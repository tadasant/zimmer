# frozen_string_literal: true

require "test_helper"

# A trigger left holding a native email or whatsapp condition after those types were removed is
# disabled once, and logged; nothing else is touched.
class DisableTriggersWithRetiredEmailAndWhatsappConditionsTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20261123020000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  test "disables the triggers with a retired condition, logs them, and leaves the rest alone" do
    email = trigger_with("Inbox triage", "email", { "query" => "in:inbox" })
    whatsapp = trigger_with("All chats", "whatsapp", { "chat_id" => "*", "mode" => "listen" })
    already_off = trigger_with("Old inbox", "email", { "query" => "in:inbox" }, status: "disabled")
    schedule = trigger_with("Hourly", "schedule", { "unit" => "hours", "interval" => 1 })

    logger = ActiveSupport::Logger.new(io = StringIO.new)
    run, outcome = run_task(logger: logger)

    assert_nil outcome
    assert_equal 2, run.stats["disabled"]
    assert_equal [ email.id, whatsapp.id ].sort, run.stats["disabled_trigger_ids"]
    assert_equal "disabled", email.reload.status
    assert_equal "disabled", whatsapp.reload.status
    assert_equal "disabled", already_off.reload.status
    assert_equal "enabled", schedule.reload.status
    assert_equal %w[email], email.trigger_conditions.pluck(:condition_type), "the condition row is kept for reference"
    assert_match(/Disabled trigger #{email.id} \("Inbox triage"\)/, io.string)
    assert_match(/Disabled trigger #{whatsapp.id} \("All chats"\)/, io.string)

    second, = run_task(logger: logger)
    assert_equal 0, second.stats["disabled"], "a second run changes nothing"
  end

  private

  # The retired types no longer validate, so the condition is written the way a row that survived
  # the deploy would look: straight to the table.
  def trigger_with(name, condition_type, configuration, status: "enabled")
    trigger = Trigger.create!(name: name, status: status, agent_root_name: "zimmer", prompt_template: "go",
                              trigger_conditions_attributes: [ { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 1 } } ])
    trigger.trigger_conditions.first.update_columns(condition_type: condition_type, configuration: configuration)
    trigger
  end

  def run_task(logger:)
    run = PostDeployTaskRun.create!(
      version: "#{@entry.version}-#{SecureRandom.hex(4)}",
      name: @entry.task_name,
      status: "pending"
    )
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    outcome = @task_class.new(run: run, logger: logger).up
    [ run.reload, outcome ]
  end
end
