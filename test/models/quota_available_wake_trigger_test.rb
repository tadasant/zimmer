# frozen_string_literal: true

require "test_helper"

# The contract between the seeded `quota_available` trigger and the catalog it
# fires into.
#
# The trigger is the ONLY thing that wakes a quota-parked spot session, and it
# spawns its session on a named agent root. If that root does not resolve, every
# fire raises inside SystemEventTriggerJob and the whole spot queue silently
# stops moving — the failure mode with no symptom other than sessions sitting in
# `waiting`. The migration seeds the row; nothing else checks that what it names
# exists, because the test database is loaded from `schema.rb` and never runs it.
class QuotaAvailableWakeTriggerTest < ActiveSupport::TestCase
  # Loaded rather than required at the top: a migration class is not autoloaded,
  # and the constant is what pins the test to the value that actually ships.
  setup do
    require Rails.root.join("db/migrate/20260821170200_seed_quota_available_wake_trigger.rb")
  end

  test "the agent root the wake trigger spawns on exists in the catalog" do
    root = SeedQuotaAvailableWakeTrigger::AGENT_ROOT

    assert AgentRootsConfig.exists?(root),
      "The seeded quota_available trigger spawns its session on the `#{root}` agent root. " \
      "It is not in the resolved catalog, so every fire would raise and no quota-parked spot " \
      "session would ever wake. Add the root to the catalog, or change the constant."
  end

  # The skill is named in the prompt rather than in `catalog_skills`, so a
  # missing one does not fail the fire — the session just would not know what to
  # do. Assert the name is still the one the catalog carries.
  test "the wake prompt names the skill that encodes the wake policy" do
    assert_includes SeedQuotaAvailableWakeTrigger::PROMPT, "awaken-waiting-sessions"
  end

  test "the event it listens for is one the monitor can fire" do
    assert_includes TriggerCondition::SYSTEM_EVENT_NAMES, QuotaAvailabilityMonitor::EVENT_NAME
  end
end
