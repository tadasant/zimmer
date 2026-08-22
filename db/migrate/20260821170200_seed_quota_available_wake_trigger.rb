# frozen_string_literal: true

# The cutover from per-session retry timers to one fleet wake, shipped with the
# deploy rather than left as a shell step nobody can take.
#
# Two halves, both idempotent:
#
#   1. Create the single `quota_available` trigger, if it is not already there.
#      It spawns one fleet-maintenance session per pool recovery, which runs the
#      `awaken-waiting-sessions` skill and decides — in precedence order, against
#      the spot thresholds and the concurrency ceiling — which waiting sessions
#      start.
#   2. Delete the leftover "Auth outage retry for session #N" triggers. Nothing
#      creates them any more (see AuthOutageParkService), and each one that
#      survived would fire a wake that ignores precedence — which is the arbitrary
#      start this whole change replaces. The sessions they pointed at are not
#      stranded: they are in `waiting` with their outage metadata intact, so the
#      fleet wake and the priority sweep both still find them.
#
# Raw SQL rather than the models, so this keeps meaning the same thing if Trigger
# or TriggerCondition change shape later.
class SeedQuotaAvailableWakeTrigger < ActiveRecord::Migration[8.0]
  TRIGGER_NAME = "Quota available — wake waiting sessions"
  AGENT_ROOT = "fleet-maintenance"
  LEGACY_NAME_PREFIX = "Auth outage retry for session #"

  PROMPT = <<~PROMPT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    The Claude Code account pool has capacity again after being exhausted.

    Run the `awaken-waiting-sessions` skill. It decides which `waiting` sessions to
    start now — in precedence order, honoring the spot utilization thresholds and the
    max-concurrency ceiling on /quotas — and starts them.

    Do not start sessions the skill does not select, and do not change any session's
    scheduling class or precedence to make it eligible. When you are done, archive
    yourself.
  PROMPT

  def up
    delete_legacy_retry_triggers!
    return if trigger_exists?

    execute(<<~SQL.squish)
      INSERT INTO triggers (
        name, agent_root_name, prompt_template, status, scheduling_class,
        mcp_servers, catalog_skills, catalog_hooks, catalog_plugins,
        reuse_session, resuscitate_archived, enqueue_messages,
        sessions_created_count, burst_window_count, burst_window_session_ids,
        created_at, updated_at
      ) VALUES (
        #{quote(TRIGGER_NAME)}, #{quote(AGENT_ROOT)}, #{quote(PROMPT)}, 'enabled', 'priority',
        '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
        false, false, false,
        0, 0, '[]'::jsonb,
        NOW(), NOW()
      )
    SQL

    execute(<<~SQL.squish)
      INSERT INTO trigger_conditions (trigger_id, condition_type, configuration, created_at, updated_at)
      SELECT id, 'system_event', '{"event_name":"quota_available"}'::jsonb, NOW(), NOW()
      FROM triggers WHERE name = #{quote(TRIGGER_NAME)}
    SQL
  end

  def down
    execute(<<~SQL.squish)
      DELETE FROM trigger_conditions
      WHERE trigger_id IN (SELECT id FROM triggers WHERE name = #{quote(TRIGGER_NAME)})
    SQL
    execute("DELETE FROM triggers WHERE name = #{quote(TRIGGER_NAME)}")
  end

  private

  def trigger_exists?
    select_value("SELECT 1 FROM triggers WHERE name = #{quote(TRIGGER_NAME)} LIMIT 1").present?
  end

  # `failed` triggers are left alone for the reason CleanupStaleTriggersJob leaves
  # them: one parked there is a deliberate tombstone an operator has not cleared.
  def delete_legacy_retry_triggers!
    pattern = quote("#{LEGACY_NAME_PREFIX}%")

    execute(<<~SQL.squish)
      DELETE FROM trigger_conditions
      WHERE trigger_id IN (
        SELECT id FROM triggers WHERE name LIKE #{pattern} AND status <> 'failed'
      )
    SQL
    execute("DELETE FROM triggers WHERE name LIKE #{pattern} AND status <> 'failed'")
  end
end
