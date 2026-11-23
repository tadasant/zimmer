# frozen_string_literal: true

# Disables every trigger that still carries a native `email` or `whatsapp` condition.
#
# Both condition types are gone: MCP event conditions (strad's Gmail `message_received` and
# WhatsApp `message_received` events) replaced them, and their pollers, services and form fields
# were deleted with them. A row that survived the deploy is inert — no poller reads it — but it is
# also invalid: TriggerCondition no longer lists the type, so the trigger looks enabled while it
# can never fire, and an edit that touches the condition fails validation. Disabling it says what
# is true. The condition rows are left in place, unchanged, so whoever re-creates the trigger as an
# `mcp_event` one can still read what it watched.
#
# Each trigger it disables is logged at WARN with its id and name.
#
# A `failed` trigger is disabled too, and sheds its failure state the way any move off `failed`
# does (Trigger#clear_failure_state_when_leaving_failed, which update_columns skips).
#
# IDEMPOTENT. It only touches triggers that are not already disabled, so a second run changes
# nothing. Its answer is in `post_deploy_task_runs` (on /health, in `GET /api/v1/health`, from
# `get_system_health` and at /supervisor/post_deploy_task_runs): how many triggers it disabled and
# their ids.
class DisableTriggersWithRetiredEmailAndWhatsappConditions < PostDeployTask
  RETIRED_CONDITION_TYPES = %w[email whatsapp].freeze

  def self.candidates
    Trigger.where(id: TriggerCondition.where(condition_type: RETIRED_CONDITION_TYPES).select(:trigger_id))
           .where.not(status: "disabled")
  end

  def up
    disabled = []
    self.class.candidates.order(:id).find_each do |trigger|
      # update_columns, not disable!: the trigger's retired condition no longer validates.
      trigger.update_columns(status: "disabled", failed_at: nil, last_error: nil, updated_at: Time.current)
      logger.warn("[DisableTriggersWithRetiredEmailAndWhatsappConditions] Disabled trigger #{trigger.id} " \
                  "(#{trigger.name.inspect}): it has a retired email or whatsapp condition. " \
                  "Re-create it as an mcp_event trigger.")
      disabled << trigger.id
    end

    checkpoint!(disabled: disabled.size, disabled_trigger_ids: disabled)
    nil
  end
end
