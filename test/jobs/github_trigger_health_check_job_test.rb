# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubTriggerHealthCheckJobTest < ActiveJob::TestCase
  # The production cache is null_store in test, which would make every heartbeat read
  # return nil and every write a no-op — the job would only ever exercise its
  # seed-and-skip branch. Swap in a real MemoryStore so the staleness comparison is
  # actually tested. Same pattern as SystemHealthMonitorJobTest.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)

    # The job preflights `gh auth status`; default it to configured so the tests below
    # exercise the staleness logic rather than the graceful-degradation early return.
    GithubSearchService.stubs(:configured?).returns(true)
  end

  teardown do
    Rails.cache = @original_cache
  end

  def heartbeat
    Rails.cache.read(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)
  end

  def write_heartbeat(at)
    Rails.cache.write(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY, at.utc.iso8601)
  end

  # ── Guards: an absent poller is not an incident ────────────────────────────

  test "does nothing when gh is not authenticated" do
    # Staging ships no gh credential, so the poller never runs there and never writes a
    # heartbeat. That expected gap must not page every 5 minutes.
    GithubSearchService.stubs(:configured?).returns(false)
    AlertService.expects(:raise_alert).never

    write_heartbeat(2.hours.ago)
    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
  end

  test "does nothing when there are no enabled GitHub triggers to poll" do
    # With nothing to poll the poller returns early every tick and never heartbeats;
    # that silence is correct, not a stall.
    Trigger.with_github_conditions.destroy_all
    AlertService.expects(:raise_alert).never

    write_heartbeat(2.hours.ago)
    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
  end

  # ── Staleness ──────────────────────────────────────────────────────────────

  test "does not alert while the poller is heartbeating normally" do
    AlertService.expects(:raise_alert).never

    write_heartbeat(1.minute.ago)
    GithubTriggerHealthCheckJob.perform_now
  end

  test "does not alert just under the staleness threshold" do
    AlertService.expects(:raise_alert).never

    write_heartbeat((GithubTriggerHealthCheckJob::STALE_THRESHOLD - 1.minute).ago)
    GithubTriggerHealthCheckJob.perform_now
  end

  test "alerts once the poller has gone quiet past the threshold" do
    # The incident: polling silently froze and nothing said so. The heartbeat is the
    # signal that survives a hung subprocess or a downed worker, neither of which runs
    # any code that could raise.
    stalled_since = 50.minutes.ago
    write_heartbeat(stalled_since)

    AlertService.expects(:raise_alert).once.with do |title, opts|
      title == "GitHub trigger polling stalled" &&
        opts[:source] == "GithubTriggerHealthCheckJob" &&
        opts[:dedup_key] == GithubTriggerHealthCheckJob::ALERT_DEDUP_KEY &&
        opts[:details].include?("50 minutes")
    end

    GithubTriggerHealthCheckJob.perform_now
  end

  test "a stalled poller pages under one stable dedup key, so an outage does not spam" do
    # AlertService throttles a repeated dedup_key to one message per DEDUP_WINDOW (1h).
    # What this job must guarantee is that every run of one outage reuses the SAME key
    # rather than minting a fresh one as the age climbs — otherwise the throttle never
    # engages and a multi-hour outage pages every run.
    keys = []
    AlertService.expects(:raise_alert).twice.with do |_title, opts|
      keys << opts[:dedup_key]
      true
    end

    write_heartbeat(30.minutes.ago)
    GithubTriggerHealthCheckJob.perform_now
    write_heartbeat(90.minutes.ago)
    GithubTriggerHealthCheckJob.perform_now

    assert_equal 1, keys.uniq.size, "an ongoing stall must reuse one dedup key so AlertService can throttle it"
  end

  # ── Baseline handling ──────────────────────────────────────────────────────

  test "seeds a baseline instead of alerting when no heartbeat exists yet" do
    # A fresh boot or a cache flush leaves an absence we cannot date; paging on it would
    # be a false alarm. Seed so the NEXT check has a real reference point.
    AlertService.expects(:raise_alert).never
    assert_nil heartbeat

    GithubTriggerHealthCheckJob.perform_now

    assert_not_nil heartbeat, "a missing heartbeat should be seeded"
    assert_in_delta Time.current.to_f, Time.iso8601(heartbeat).to_f, 5
  end

  test "a seeded baseline still catches a stall that never resolves" do
    # Seeding must not become an amnesia loop that re-arms itself forever. If the poller
    # stays dead, the seed itself ages past the threshold and the next check pages.
    # Exactly one alert across both runs proves the seeding run stayed quiet AND the
    # aged-seed run fired.
    AlertService.expects(:raise_alert).once

    GithubTriggerHealthCheckJob.perform_now # no heartbeat -> seeds "now", stays quiet

    travel_to(Time.current + GithubTriggerHealthCheckJob::STALE_THRESHOLD + 1.minute) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "reseeds rather than crashing on an unparseable heartbeat" do
    AlertService.expects(:raise_alert).never
    Rails.cache.write(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY, "not-a-timestamp")

    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
    assert_in_delta Time.current.to_f, Time.iso8601(heartbeat).to_f, 5
  end
end
