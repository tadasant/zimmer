# frozen_string_literal: true

# Seeds the Trigger that turns the `account_needs_reauth` event into a Slack DM.
#
# WHY A MIGRATION
# ---------------
# The event is useless without a trigger watching it, and there is no other way to
# put one in place: live Trigger rows are not reachable from an agent session, so
# "a human will add it" means the feature ships dead and nobody notices until the
# next dead account says nothing.
#
# This covers a deployment with an EXISTING database. It does not cover a fresh
# one, because `db:prepare` loads `schema.rb` there rather than running migrations,
# so this file never executes — `db/seeds.rb` is the fresh-install path and calls
# `up` directly. Both are needed; the users table splits the same way for the same
# reason.
#
# WHY RAW SQL
# -----------
# Trigger validates `agent_root_name`, `mcp_servers` and `catalog_skills` against
# the AIR catalog, which is a RUNTIME dependency resolved by shelling out to the
# `air` CLI. A migration must be deterministic and must run on a box where that
# resolve may fail; going through the model would make schema migration depend on
# catalog resolution. The ids written here (`general-agent`, `slack-workspace`)
# are checked against the catalog by test/models/trigger_test.rb's seeded-trigger
# test instead, where a failed resolve is a test failure rather than a stuck deploy.
#
# EDITING THIS ROW IS EXPECTED. It is a starting point, not a fixture: the prompt,
# the burst cap and the agent root are all editable at /triggers, and nothing
# re-asserts them. `down` removes the row only while it still carries the name and
# the condition this migration gave it.
class SeedAccountNeedsReauthTrigger < ActiveRecord::Migration[8.1]
  NAME = "Account needs re-authentication → DM the operator"
  EVENT_NAME = "account_needs_reauth"

  PROMPT = <<~PROMPT
    {{event}}

    A runtime account in this Zimmer deployment's pool can no longer refresh its
    OAuth token. The pool has stopped drawing on it and it stays out of rotation
    until a human re-authenticates it — Zimmer cannot recover this on its own.

    Your whole job is to tell that human, over Slack, using the slack-workspace
    MCP server:

    1. Send a direct message to the person who operates this Zimmer deployment.
       If you are not sure who that is, look at who receives Zimmer's other
       operator DMs, or ask in the engineering alerts channel.
    2. Say which account is affected — it is named in the event line above — and
       that fixing it means opening Zimmer's /quotas page and pressing
       "Authenticate" on that account's card.
    3. If the DM cannot be delivered for any reason (missing scope, unknown user,
       Slack error), post the same message to the engineering alerts channel
       instead and say in your final message that the DM failed and why. A
       notification nobody can see is the failure this trigger exists to end, so
       do not finish quietly on a send that did not work.

    Send one message. Do not investigate the account, do not change any code, and
    do not open a pull request. Archive yourself when the message is sent.
  PROMPT

  def up
    return if seeded_trigger_exists?

    say "Seeding the #{EVENT_NAME} trigger"

    # NOT `.squish`: the prompt is interpolated into this statement as a quoted
    # literal, and squishing the statement squishes the literal with it — which
    # would deliver the agent one run-on paragraph instead of a numbered list.
    execute(<<~SQL)
      WITH new_trigger AS (
        INSERT INTO triggers (
          name, agent_root_name, prompt_template, mcp_servers, catalog_skills,
          status, scheduling_class, max_sessions_per_minute, reuse_session,
          created_at, updated_at
        ) VALUES (
          #{quote(NAME)},
          #{quote("general-agent")},
          #{quote(PROMPT)},
          #{quote([ "slack-workspace" ].to_json)}::jsonb,
          '[]'::jsonb,
          'enabled',
          'priority',
          3,
          false,
          NOW(), NOW()
        )
        RETURNING id
      )
      INSERT INTO trigger_conditions (trigger_id, condition_type, configuration, created_at, updated_at)
      SELECT id, 'ao_event', #{quote({ event_name: EVENT_NAME }.to_json)}::jsonb, NOW(), NOW()
      FROM new_trigger
    SQL
  end

  # Conditions first: `trigger_conditions.trigger_id` is a plain foreign key with
  # no ON DELETE clause, so Postgres RESTRICTs a trigger delete while any condition
  # still points at it. The cascade the app relies on is `dependent: :destroy` on
  # the model, which raw SQL does not go through.
  #
  # The ids are resolved ONCE, up front, and then used as literals. They cannot be
  # re-derived after the first DELETE: the query that identifies a seeded trigger
  # JOINs the very conditions this method has just removed, so a second lookup
  # matches nothing and the trigger rows survive as orphans.
  def down
    ids = select_values(seeded_trigger_ids_sql).map(&:to_i)
    return if ids.empty?

    list = ids.join(", ")
    execute("DELETE FROM trigger_conditions WHERE trigger_id IN (#{list})")
    execute("DELETE FROM triggers WHERE id IN (#{list})")
  end

  private

  # The rows this migration created, and only those: the name AND the condition
  # both have to still match, so a trigger a human has renamed or repurposed is
  # left alone by `down`.
  def seeded_trigger_ids_sql
    <<~SQL.squish
      SELECT t.id FROM triggers t
      JOIN trigger_conditions c ON c.trigger_id = t.id
      WHERE t.name = #{quote(NAME)}
        AND c.condition_type = 'ao_event'
        AND c.configuration ->> 'event_name' = #{quote(EVENT_NAME)}
    SQL
  end

  # Keyed on the CONDITION, not on the trigger's name: a human who has renamed the
  # row, or wired the event onto a trigger of their own, already has what this
  # migration would provide, and a second one would double every notification.
  def seeded_trigger_exists?
    select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM trigger_conditions
      WHERE condition_type = 'ao_event'
        AND configuration ->> 'event_name' = #{quote(EVENT_NAME)}
    SQL
  end

  # Reached through the connection rather than Migration's method_missing, which
  # would rewrite the first argument via proper_table_name.
  def quote(value) = connection.quote(value)
end
