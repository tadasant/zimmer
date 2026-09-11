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

  test "does not seed or alert on an unconfigured host that has never polled" do
    # Staging ships no gh credential, so its poller never runs and never heartbeats. That
    # expected gap must not page every 5 minutes — and must not be seeded either, or the
    # seed would age into a page for a poller that was never supposed to be running.
    GithubSearchService.stubs(:configured?).returns(false)
    ErrorReporter.expects(:report_message).never

    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
    assert_nil heartbeat, "an unconfigured host must not be given a baseline"
  end

  test "alerts on a stale heartbeat even when the gh preflight is failing" do
    # Regression test for the trap this job is most likely to fall into. `configured?`
    # shells out to `gh auth status`, a LIVE API call — so a GitHub REST outage makes it
    # return false. Guarding the whole check on it would hand this job exactly the silence
    # it exists to break: the poller stalls, the preflight fails, and nobody is told.
    # A heartbeat that EXISTS proves this host polls GitHub, so a stale one is an incident
    # whatever the preflight says — including when polling stopped because the credential
    # was revoked.
    GithubSearchService.stubs(:configured?).returns(false)
    write_heartbeat(50.minutes.ago)

    ErrorReporter.expects(:report_message).once.with do |message, _opts|
      message == "GitHub trigger polling stalled"
    end

    GithubTriggerHealthCheckJob.perform_now
  end

  test "does nothing when there are no enabled GitHub triggers to poll" do
    # With nothing to poll the poller returns early every tick and never heartbeats;
    # that silence is correct, not a stall.
    Trigger.with_github_conditions.destroy_all
    ErrorReporter.expects(:report_message).never

    write_heartbeat(2.hours.ago)
    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
  end

  # ── Staleness ──────────────────────────────────────────────────────────────

  test "does not alert while the poller is heartbeating normally" do
    ErrorReporter.expects(:report_message).never

    write_heartbeat(1.minute.ago)
    GithubTriggerHealthCheckJob.perform_now
  end

  test "does not alert just under the staleness threshold" do
    ErrorReporter.expects(:report_message).never

    write_heartbeat((GithubTriggerHealthCheckJob::STALE_THRESHOLD - 1.minute).ago)
    GithubTriggerHealthCheckJob.perform_now
  end

  test "alerts once the poller has gone quiet past the threshold" do
    # The incident: polling silently froze and nothing said so. The heartbeat is the
    # signal that survives a hung subprocess or a downed worker, neither of which runs
    # any code that could raise.
    stalled_since = 50.minutes.ago
    write_heartbeat(stalled_since)

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "GitHub trigger polling stalled" &&
        opts[:level] == :error &&
        opts[:context][:source] == "GithubTriggerHealthCheckJob" &&
        opts[:context][:details].include?("50 minutes")
    end

    entries = capture_log_entries { GithubTriggerHealthCheckJob.perform_now }

    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size, "the stall emits the ERROR record that pages"
    assert_match(/No successful GitHub trigger poll/, errors.first.last)
  end

  test "a stalled poller reports one stable message, so an outage does not spam" do
    # Grouping is done downstream now: GlitchTip groups by message and notifies at most
    # once per issue, and Grafana groups by alertname. What this job must guarantee is
    # that every run of one outage reports the SAME message rather than minting a fresh
    # one as the age climbs (the age rides in the context, which does not group) —
    # otherwise a multi-hour outage opens a new issue on every run.
    messages = []
    ErrorReporter.expects(:report_message).twice.with do |message, _opts|
      messages << message
      true
    end

    write_heartbeat(30.minutes.ago)
    GithubTriggerHealthCheckJob.perform_now
    write_heartbeat(90.minutes.ago)
    GithubTriggerHealthCheckJob.perform_now

    assert_equal 1, messages.uniq.size, "an ongoing stall must report one message, so GlitchTip groups it"
  end

  # ── Baseline handling ──────────────────────────────────────────────────────

  test "seeds a baseline instead of alerting when no heartbeat exists yet" do
    # A fresh boot or a cache flush leaves an absence we cannot date; paging on it would
    # be a false alarm. Seed so the NEXT check has a real reference point.
    ErrorReporter.expects(:report_message).never
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
    ErrorReporter.expects(:report_message).once

    GithubTriggerHealthCheckJob.perform_now # no heartbeat -> seeds "now", stays quiet

    travel_to(Time.current + GithubTriggerHealthCheckJob::STALE_THRESHOLD + 1.minute) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "reseeds rather than crashing on an unparseable heartbeat" do
    ErrorReporter.expects(:report_message).never
    Rails.cache.write(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY, "not-a-timestamp")

    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
    assert_in_delta Time.current.to_f, Time.iso8601(heartbeat).to_f, 5
  end
end
