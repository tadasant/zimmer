# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TriggerPollerLivenessCheckJobTest < ActiveJob::TestCase
  include GithubRateLimitStateHelpers

  # The production cache is null_store in test, which would make every heartbeat read
  # return nil and every write a no-op — the job would only ever exercise its
  # seed-and-skip branch. Swap in a real MemoryStore so the staleness comparison is
  # actually tested. Same pattern as SystemHealthMonitorJobTest.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Both pollers preflight a credential before they are seeded; default both to
    # configured so the tests below exercise the staleness logic rather than the
    # graceful-degradation early return.
    GithubSearchService.stubs(:configured?).returns(true)
    SlackService.stubs(:configured?).returns(true)
    use_test_gh_token
  end

  teardown do
    Rails.cache = @original_cache
    restore_gh_tokens
  end

  def write_heartbeat(poller, at)
    Rails.cache.write(PollerHeartbeat.cache_key(poller), at.utc.iso8601)
  end

  def github_poller = TriggerPollerLivenessCheckJob::POLLERS.find { |p| p.key == :github }
  def slack_poller = TriggerPollerLivenessCheckJob::POLLERS.find { |p| p.key == :slack }

  def expect_page(title)
    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == title && opts[:level] == :error &&
        opts[:context][:source] == "TriggerPollerLivenessCheckJob"
    end
  end

  # ── Guards: an absent poller is not an incident ────────────────────────────

  test "does not seed or alert on an unconfigured GitHub host that has never polled" do
    # Staging ships no gh credential, so its poller never runs and never heartbeats. That
    # expected gap must not page every 5 minutes — and must not be seeded either, or the
    # seed would age into a page for a poller that was never supposed to be running.
    GithubSearchService.stubs(:configured?).returns(false)
    write_heartbeat(:slack, 1.minute.ago)
    ErrorReporter.expects(:report_message).never

    assert_nothing_raised { TriggerPollerLivenessCheckJob.perform_now }
    assert_nil PollerHeartbeat.raw(:github), "an unconfigured host must not be given a baseline"
  end

  test "does not seed or alert on a host with no Slack token that has never polled" do
    SlackService.stubs(:configured?).returns(false)
    write_heartbeat(:github, 1.minute.ago)
    ErrorReporter.expects(:report_message).never

    assert_nothing_raised { TriggerPollerLivenessCheckJob.perform_now }
    assert_nil PollerHeartbeat.raw(:slack), "a host with no Slack token must not be given a baseline"
  end

  test "alerts on a stale GitHub heartbeat even when the gh preflight is failing" do
    # Regression test for the trap this job is most likely to fall into. `configured?`
    # shells out to `gh auth status`, a LIVE API call — so a GitHub REST outage makes it
    # return false. Guarding the whole check on it would hand this job exactly the silence
    # it exists to break: the poller stalls, the preflight fails, and nobody is told.
    # A heartbeat that EXISTS proves this host polls GitHub, so a stale one is an incident
    # whatever the preflight says — including when polling stopped because the credential
    # was revoked.
    GithubSearchService.stubs(:configured?).returns(false)
    write_heartbeat(:github, 50.minutes.ago)
    write_heartbeat(:slack, 1.minute.ago)

    expect_page("GitHub trigger polling stalled")

    TriggerPollerLivenessCheckJob.perform_now
  end

  test "does nothing for a poller with no enabled triggers to poll" do
    # With nothing to poll the poller has nothing to do and its heartbeat says nothing;
    # that silence is correct, not a stall.
    Trigger.with_github_conditions.destroy_all
    TriggerCondition.slack.joins(:trigger).where(triggers: { status: "enabled" }).destroy_all
    ErrorReporter.expects(:report_message).never

    write_heartbeat(:github, 2.hours.ago)
    write_heartbeat(:slack, 2.hours.ago)
    assert_nothing_raised { TriggerPollerLivenessCheckJob.perform_now }
  end

  # ── Staleness ──────────────────────────────────────────────────────────────

  test "does not alert while both pollers are heartbeating normally" do
    ErrorReporter.expects(:report_message).never

    write_heartbeat(:github, 1.minute.ago)
    write_heartbeat(:slack, 1.minute.ago)
    TriggerPollerLivenessCheckJob.perform_now
  end

  test "does not alert just under each poller's own threshold" do
    ErrorReporter.expects(:report_message).never

    write_heartbeat(:github, (github_poller.threshold.call - 1.minute).ago)
    write_heartbeat(:slack, (slack_poller.threshold - 1.minute).ago)
    TriggerPollerLivenessCheckJob.perform_now
  end

  test "the Slack threshold is wider than the GitHub one, past the poller's deferral chain" do
    # The Slack poller's own deferral chain holds the singleton for ~15 minutes across five
    # backoffs and then pages by itself; a liveness threshold inside that window would page
    # a second time for an outage the poller is already reporting.
    assert_operator slack_poller.threshold, :>, github_poller.threshold.call
    assert_operator slack_poller.threshold, :>=, 30.minutes
  end

  test "alerts once the GitHub poller has gone quiet past its threshold" do
    # The incident: polling silently froze and nothing said so. The heartbeat is the
    # signal that survives a hung subprocess or a downed worker, neither of which runs
    # any code that could raise.
    write_heartbeat(:github, 50.minutes.ago)
    write_heartbeat(:slack, 1.minute.ago)

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "GitHub trigger polling stalled" &&
        opts[:context][:poller] == "github" &&
        opts[:context][:details].include?("50 minutes")
    end

    entries = capture_log_entries { TriggerPollerLivenessCheckJob.perform_now }

    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size, "the stall emits the ERROR record that pages"
    assert_match(/No successful github trigger poll/, errors.first.last)
  end

  # 2026-11-15: the page fired for a spent rate limit and its text listed only a dead worker,
  # a hung `gh` and an unreachable GitHub. The page fires exactly as before; its details now
  # say what this host knows.
  test "a GitHub stall beside a spent core budget pages under the usual title, and says polling continues through it" do
    write_heartbeat(:github, 20.minutes.ago)
    reset = 12.minutes.from_now
    open_rate_limit_breaker("core", reset)
    write_rate_limit_snapshot("core" => [ 0, 5000, reset ], "search" => [ 28, 30, 40.seconds.from_now ])
    remember_github_login("tadasant")
    reset_text = reset.utc.strftime("%Y-%m-%d %H:%M UTC")

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      details = opts[:context][:details]
      message == "GitHub trigger polling stalled" &&
        # The diagnosis leads the details, and the generic causes follow it.
        details.start_with?("GitHub rate limit: GH_TOKEN (tadasant)'s core budget is spent: 0/5000 left, resets #{reset_text} (in 12 min).") &&
        details.include?("GitHub trigger polling continues through it") &&
        details.include?("rate limit is spent") &&
        opts[:context][:diagnosis].include?(reset_text) &&
        !details.include?(TEST_GH_TOKEN)
    end

    entries = capture_log_entries { TriggerPollerLivenessCheckJob.perform_now }
    error = entries.find { |severity, _message| severity == "ERROR" }
    assert_match(/\[TriggerPollerLivenessCheckJob\] No successful github trigger poll/, error.last)
    assert_includes error.last, "core budget is spent: 0/5000 left, resets #{reset_text}"
  end

  test "a GitHub stall while the search budget is spent keeps the usual title, and the details lead with the reading" do
    write_heartbeat(:github, 20.minutes.ago)
    write_rate_limit_snapshot("core" => [ 4000, 5000, 30.minutes.from_now ], "search" => [ 0, 30, 40.seconds.from_now ])

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      # A one-minute search window cannot explain a quarter of an hour, so the title does
      # not claim it as the cause; the reading rides in the details for the responder.
      message == "GitHub trigger polling stalled" &&
        opts[:level] == :error &&
        opts[:context][:details].start_with?("GitHub rate limit: GH_TOKEN's search budget is spent: 0/30 left") &&
        opts[:context][:details].include?("GitHub trigger polling is paused until then.")
    end

    entries = capture_log_entries { TriggerPollerLivenessCheckJob.perform_now }
    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size, "still exactly one ERROR record: the page"
  end

  test "a spent search budget with a fresh heartbeat does not page" do
    write_heartbeat(:github, 2.minutes.ago)
    write_rate_limit_snapshot("search" => [ 0, 30, 40.seconds.from_now ])

    ErrorReporter.expects(:report_message).never
    TriggerPollerLivenessCheckJob.perform_now
  end

  # The guard on the whole change: nothing about rate limits may quiet a real outage.
  test "a GitHub stall with no rate-limit finding still pages, with the generic text and no diagnosis attached" do
    write_heartbeat(:github, 20.minutes.ago)

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "GitHub trigger polling stalled" && !opts[:context].key?(:diagnosis) &&
        opts[:context][:details].start_with?("No GitHub trigger poll has completed successfully in ~20 minutes")
    end

    TriggerPollerLivenessCheckJob.perform_now
  end

  test "a diagnosis that raises does not cost the page" do
    write_heartbeat(:github, 20.minutes.ago)
    GithubRateLimitReport.stubs(:diagnosis).raises(RuntimeError, "boom")

    ErrorReporter.expects(:report_message).once.with { |message, _opts| message == "GitHub trigger polling stalled" }

    TriggerPollerLivenessCheckJob.perform_now
  end

  test "alerts once the Slack poller has gone quiet past its threshold" do
    # The gap #525 names: the Slack poller had no heartbeat at all, so a wedged singleton
    # or a dead worker was invisible until a feed drifted three hours behind — and the
    # freshness check that would notice runs on the same worker.
    write_heartbeat(:github, 1.minute.ago)
    write_heartbeat(:slack, 45.minutes.ago)

    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "Slack trigger polling stalled" &&
        opts[:context][:poller] == "slack" &&
        opts[:context][:details].include?("45 minutes")
    end

    entries = capture_log_entries { TriggerPollerLivenessCheckJob.perform_now }

    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size, "the stall emits the ERROR record that pages"
    assert_match(/No successful slack trigger poll/, errors.first.last)
  end

  test "each poller is judged on its own heartbeat" do
    # A fresh GitHub heartbeat must not cover for a stale Slack one, or the other way
    # round: the two feeds fail independently and page independently.
    write_heartbeat(:github, 2.hours.ago)
    write_heartbeat(:slack, 2.hours.ago)

    titles = []
    ErrorReporter.expects(:report_message).twice.with { |message, _opts| titles << message; true }

    TriggerPollerLivenessCheckJob.perform_now

    assert_equal [ "GitHub trigger polling stalled", "Slack trigger polling stalled" ], titles.sort
  end

  test "a stalled poller reports one stable message, so an outage pages once per dedup window" do
    # Grouping is done downstream: GlitchTip groups by message and notifies at most once
    # per issue, and Grafana groups by alertname. What this job must guarantee is that
    # every run of one outage reports the SAME message rather than minting a fresh one as
    # the age climbs (the age rides in the context, which does not group) — otherwise a
    # multi-hour outage opens a new issue on every run.
    write_heartbeat(:github, 1.minute.ago)
    messages = []
    ErrorReporter.expects(:report_message).twice.with do |message, _opts|
      messages << message
      true
    end

    write_heartbeat(:slack, 40.minutes.ago)
    TriggerPollerLivenessCheckJob.perform_now
    write_heartbeat(:slack, 90.minutes.ago)
    TriggerPollerLivenessCheckJob.perform_now

    assert_equal 1, messages.uniq.size, "an ongoing stall must report one message, so GlitchTip groups it"
  end

  # ── Baseline handling ──────────────────────────────────────────────────────

  test "seeds a baseline instead of alerting when no heartbeat exists yet" do
    # A fresh boot or a cache flush leaves an absence we cannot date; paging on it would
    # be a false alarm. Seed so the NEXT check has a real reference point. The Slack
    # heartbeat is new with #525, so every production host takes this path once.
    ErrorReporter.expects(:report_message).never
    assert_nil PollerHeartbeat.raw(:github)
    assert_nil PollerHeartbeat.raw(:slack)

    TriggerPollerLivenessCheckJob.perform_now

    %i[github slack].each do |poller|
      assert_not_nil PollerHeartbeat.raw(poller), "a missing #{poller} heartbeat should be seeded"
      assert_in_delta Time.current.to_f, PollerHeartbeat.last_at(poller).to_f, 5
    end
  end

  test "a seeded baseline still catches a stall that never resolves" do
    # Seeding must not become an amnesia loop that re-arms itself forever. If the poller
    # stays dead, the seed itself ages past the threshold and the next check pages.
    # Exactly one alert per poller across both runs proves the seeding run stayed quiet
    # AND the aged-seed run fired.
    ErrorReporter.expects(:report_message).twice

    TriggerPollerLivenessCheckJob.perform_now # no heartbeats -> seeds "now", stays quiet

    travel_to(Time.current + slack_poller.threshold + 1.minute) do
      TriggerPollerLivenessCheckJob.perform_now
    end
  end

  test "reseeds rather than crashing on an unparseable heartbeat" do
    ErrorReporter.expects(:report_message).never
    Rails.cache.write(PollerHeartbeat.cache_key(:github), "not-a-timestamp")
    write_heartbeat(:slack, 1.minute.ago)

    assert_nothing_raised { TriggerPollerLivenessCheckJob.perform_now }
    assert_in_delta Time.current.to_f, PollerHeartbeat.last_at(:github).to_f, 5
  end

  # ── Placement ──────────────────────────────────────────────────────────────

  # ── A slowed GitHub poller (GithubTriggerPollCadence) ───────────────────────

  def with_github_interval(minutes)
    saved = ENV[GithubTriggerPollCadence::SETTING_KEY]
    ENV[GithubTriggerPollCadence::SETTING_KEY] = minutes.to_s
    yield
  ensure
    saved.nil? ? ENV.delete(GithubTriggerPollCadence::SETTING_KEY) : ENV[GithubTriggerPollCadence::SETTING_KEY] = saved
  end

  test "the GitHub threshold is the quarter-hour at the default interval and at five minutes" do
    assert_equal 15.minutes, github_poller.threshold.call
    with_github_interval(5) { assert_equal 15.minutes, github_poller.threshold.call }
  end

  test "a poller slowed to fifteen minutes does not page through one ordinary gap between sweeps" do
    ErrorReporter.expects(:report_message).never
    write_heartbeat(:slack, 1.minute.ago)
    write_heartbeat(:github, 29.minutes.ago)

    with_github_interval(15) { TriggerPollerLivenessCheckJob.perform_now }
  end

  test "a poller slowed to fifteen minutes still pages on a real stall" do
    write_heartbeat(:slack, 1.minute.ago)
    write_heartbeat(:github, 36.minutes.ago)
    expect_page("GitHub trigger polling stalled")

    with_github_interval(15) { TriggerPollerLivenessCheckJob.perform_now }
  end

  test "at the default interval a sixteen-minute-old heartbeat pages, as it always has" do
    write_heartbeat(:slack, 1.minute.ago)
    write_heartbeat(:github, 16.minutes.ago)
    expect_page("GitHub trigger polling stalled")

    TriggerPollerLivenessCheckJob.perform_now
  end

  test "runs on default, not on the pollers queue it watches" do
    assert_equal "default", TriggerPollerLivenessCheckJob.new.queue_name
  end
end
