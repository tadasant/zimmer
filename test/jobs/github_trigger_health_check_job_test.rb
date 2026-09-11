# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The per-condition freshness half of the GitHub poller's monitor. Liveness — is the
# poller polling at all — is TriggerPollerLivenessCheckJobTest.
class GithubTriggerHealthCheckJobTest < ActiveJob::TestCase
  setup do
    @label_condition = trigger_conditions(:github_label_condition)
    @issue_condition = trigger_conditions(:github_issue_condition)
    # The job preflights `gh auth status`; default it to configured so the tests below
    # exercise the probe rather than the graceful-degradation early return.
    GithubSearchService.stubs(:configured?).returns(true)
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  STALE_AGE = GithubTriggerHealthCheckJob::STALE_THRESHOLD + 1.hour

  # An item shaped like the search-API fields the check reads.
  def item(number:, labels: [], repo: "tadasant/zimmer", created_at: 1.day.ago, updated_at: nil)
    {
      "number" => number,
      "title" => "Item #{number}",
      "html_url" => "https://github.com/#{repo}/pull/#{number}",
      "repository_url" => "https://api.github.com/repos/#{repo}",
      "labels" => labels.map { |name| { "name" => name } },
      "created_at" => created_at.utc.iso8601,
      "updated_at" => (updated_at || created_at).utc.iso8601
    }
  end

  # Stubs GithubSearchService.search_issues, dispatching on the query rather than on call
  # order: both enabled GitHub conditions are probed every run and fixture ids are hashed,
  # so the order the check visits them in is not something a test may rely on. A label
  # probe always starts with "is:open "; an issue probe with "is:issue ".
  def stub_search(label: [], issue: [])
    queries = []
    fake = lambda do |query, **opts|
      queries << [ query, opts ]
      query.start_with?("is:issue ") ? issue : label
    end
    GithubSearchService.stub(:search_issues, fake) { yield queries }
  end

  def expect_stall(condition)
    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "GitHub trigger feed stalled" &&
        opts[:level] == :error &&
        opts[:context][:source] == "GithubTriggerHealthCheckJob" &&
        opts[:context][:condition_id] == condition.id &&
        opts[:context][:trigger_id] == condition.trigger_id
    end
  end

  # ── Guards ─────────────────────────────────────────────────────────────────

  test "does nothing on a host that cannot authenticate to GitHub" do
    # Staging ships no gh credential and schedules no poller worth keeping up with. Unlike
    # the liveness check this one may guard on the preflight: a stall the preflight hides
    # is one the liveness check pages on within minutes.
    GithubSearchService.stubs(:configured?).returns(false)
    GithubSearchService.expects(:search_issues).never
    ErrorReporter.expects(:report_message).never

    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
  end

  test "does not probe a condition on a disabled trigger" do
    disabled = trigger_conditions(:disabled_github_label_condition)

    # The disabled condition's items are already in ITS seen-set, so the only way it can
    # page is by being probed at all; the stalled item below is the enabled one's.
    disabled.update!(configuration: disabled.configuration.merge("seen_items" => [ "tadasant/zimmer#1:ready to merge" ]))
    expect_stall(@label_condition)

    stub_search(label: [ item(number: 1, labels: [ "ready to merge" ], created_at: STALE_AGE.ago) ]) do |queries|
      GithubTriggerHealthCheckJob.perform_now
      assert_equal 2, queries.size, "one probe per ENABLED condition: the label one and the issue one"
    end
  end

  test "a condition that has never been polled has nothing to fall behind on" do
    # update_columns: the model merges poll state back into any configuration write, on
    # purpose — the never-polled shape can only be produced underneath it.
    @label_condition.update_columns(configuration: @label_condition.configuration.except("seen_items"))
    @issue_condition.update_columns(configuration: @issue_condition.configuration.except("last_issue_at"))
    GithubSearchService.expects(:search_issues).never
    ErrorReporter.expects(:report_message).never

    GithubTriggerHealthCheckJob.perform_now
  end

  test "a trigger inside a burst is holding its items on purpose and is not probed" do
    trigger = @label_condition.trigger
    # Two writes: changing the cap clears any burst state in the same save.
    trigger.update!(max_sessions_per_minute: 1)
    trigger.update!(burst_active_until: 5.minutes.from_now)
    ErrorReporter.expects(:report_message).never

    stub_search(label: [ item(number: 1, labels: [ "ready to merge" ], created_at: STALE_AGE.ago) ]) do |queries|
      GithubTriggerHealthCheckJob.perform_now
      assert queries.none? { |query, _| query.start_with?("is:open ") }, "the burst-held label condition must not be searched"
    end
  end

  test "a skip-while-pending trigger with a pending session is holding its items on purpose and is not probed" do
    trigger = @issue_condition.trigger
    trigger.update!(skip_if_pending_session: true)
    trigger.stubs(:pending_intent_session).returns(sessions(:running))
    TriggerCondition.any_instance.stubs(:trigger).returns(trigger)
    ErrorReporter.expects(:report_message).never

    stub_search(issue: [ item(number: 9, created_at: STALE_AGE.ago) ]) do |queries|
      GithubTriggerHealthCheckJob.perform_now
      assert queries.none? { |query, _| query.start_with?("is:issue ") }, "the held issue condition must not be searched"
    end
  end

  # ── github_label: an item labelled for hours that the seen-set does not hold ─────

  test "the label probe is the poller's own query, narrowed to items not updated within the threshold" do
    stub_search do |queries|
      GithubTriggerHealthCheckJob.perform_now

      query, opts = queries.find { |q, _| q.start_with?("is:open ") }
      assert_not_nil query
      assert_includes query, "is:pr"
      assert_includes query, "repo:tadasant/zimmer"
      assert_includes query, 'label:"ready to merge"'
      assert_match(/updated:<=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, query)
      assert_equal({ sort: "created", order: "asc" }, opts)
    end
  end

  test "alerts when a labelled item older than the threshold is missing from the seen-set" do
    # The failure the heartbeat masks: the poller is alive (its siblings keep the
    # heartbeat fresh) but THIS condition has been shown this item on every tick for
    # hours and never recorded it.
    stalled = item(number: 41, labels: [ "ready to merge" ], created_at: STALE_AGE.ago)
    expect_stall(@label_condition)

    entries = stub_search(label: [ stalled ]) do
      capture_log_entries { GithubTriggerHealthCheckJob.perform_now }
    end

    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size, "a stalled feed must emit exactly one ERROR record — that is the page"
    assert_match(/tadasant\/zimmer#41:ready to merge/, errors.first.last)
  end

  test "a stalled item still being worked on is outside the probe until it goes quiet" do
    # The documented blind spot, pinned so it stays a decision: `updated:<=` is enforced by
    # GitHub, so an item with recent activity never reaches the comparison at all. Here the
    # stub stands in for GitHub honouring the qualifier by returning nothing.
    ErrorReporter.expects(:report_message).never

    stub_search(label: []) do |queries|
      GithubTriggerHealthCheckJob.perform_now
      query, = queries.find { |q, _| q.start_with?("is:open ") }
      cutoff = Time.iso8601(query[/updated:<=(\S+)/, 1])
      assert_in_delta (Time.current - GithubTriggerHealthCheckJob::STALE_THRESHOLD).to_f, cutoff.to_f, 5,
                      "the cutoff is exactly the threshold ago, so recent activity excludes an item"
    end
  end

  test "stays quiet when every labelled item is in the seen-set" do
    @label_condition.update!(configuration: @label_condition.configuration.merge(
      "seen_items" => [ "tadasant/zimmer#41:ready to merge" ]
    ))
    ErrorReporter.expects(:report_message).never

    stub_search(label: [ item(number: 41, labels: [ "ready to merge" ], created_at: STALE_AGE.ago) ]) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "keys the seen-set comparison the way the poller does: configured casing, one key per watched label" do
    # GitHub returns its own casing; the poller stores the configured one. Comparing raw
    # strings would flag every item on a condition whose label casing differs from the
    # repo's — a false stall on every run.
    @label_condition.update!(configuration: @label_condition.configuration.merge(
      "labels" => [ "Ready To Merge" ], "seen_items" => [ "tadasant/zimmer#41:Ready To Merge" ]
    ))
    ErrorReporter.expects(:report_message).never

    stub_search(label: [ item(number: 41, labels: [ "ready to merge", "unrelated" ], created_at: STALE_AGE.ago) ]) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "a retargeted label condition is about to be re-baselined and is not judged" do
    @label_condition.update!(configuration: @label_condition.configuration.merge(
      "baseline_scope" => { "repos" => [ "tadasant/zimmer" ], "target" => "issue", "labels" => [ "ready to merge" ] }
    ))
    ErrorReporter.expects(:report_message).never

    stub_search(label: [ item(number: 41, labels: [ "ready to merge" ], created_at: STALE_AGE.ago) ]) do |queries|
      GithubTriggerHealthCheckJob.perform_now
      assert queries.none? { |query, _| query.start_with?("is:open ") }
    end
  end

  # ── github_issue: the newest issue is newer than the cursor and old ─────────────

  test "the issue probe is the poller's own query with no time bound, newest first, one bounded request" do
    stub_search do |queries|
      GithubTriggerHealthCheckJob.perform_now

      query, opts = queries.find { |q, _| q.start_with?("is:issue ") }
      assert_not_nil query
      assert_includes query, "repo:tadasant/zimmer"
      assert_not_includes query, "created:"
      assert_equal({ sort: "created", order: "desc", limit: GithubTriggerHealthCheckJob::NEWEST_ISSUES_PROBED }, opts)
    end
  end

  test "alerts when the newest issue is newer than the cursor and older than the threshold" do
    # Fixture cursor is 2026-07-01; an issue opened well after it, hours ago, that the
    # poller never advanced past.
    expect_stall(@issue_condition)

    entries = stub_search(issue: [ item(number: 900, created_at: STALE_AGE.ago) ]) do
      capture_log_entries { GithubTriggerHealthCheckJob.perform_now }
    end

    errors = entries.select { |severity, _message| severity == "ERROR" }
    assert_equal 1, errors.size
    assert_match(/tadasant\/zimmer#900/, errors.first.last)
    assert_match(/cursor 2026-07-01T00:00:00Z/, errors.first.last)
  end

  test "stays quiet when the newest issue is at or behind the cursor" do
    ErrorReporter.expects(:report_message).never

    stub_search(issue: [ item(number: 1, created_at: Time.iso8601("2026-06-30T00:00:00Z")) ]) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "stays quiet when the newest issue is newer than the cursor but still inside the threshold" do
    # The once-a-minute poller has not necessarily had its turn yet; the index lags too.
    ErrorReporter.expects(:report_message).never

    stub_search(issue: [ item(number: 901, created_at: 10.minutes.ago) ]) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "an issue that predates its repo's baseline is history the poller refuses too, and is skipped over" do
    # The repo joined the scope AFTER the issue was opened. The poller would never fire
    # it, so the probe must not read it as a stall — but must keep looking past it.
    # update_columns: editing `repos` through the model rebases the cursor, which is the
    # poller's own concern; this test wants the state exactly as written.
    @issue_condition.update_columns(configuration: @issue_condition.configuration.merge(
      "repos" => [ "tadasant/zimmer", "tadasant/strad" ],
      "issue_repo_baselines" => { "tadasant/strad" => 2.hours.ago.utc.iso8601 }
    ))
    ErrorReporter.expects(:report_message).never

    stub_search(issue: [ item(number: 5, repo: "tadasant/strad", created_at: STALE_AGE.ago) ]) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "an issue behind a pre-baseline one is still judged" do
    expect_stall(@issue_condition)
    @issue_condition.update_columns(configuration: @issue_condition.configuration.merge(
      "repos" => [ "tadasant/zimmer", "tadasant/strad" ],
      "issue_repo_baselines" => { "tadasant/strad" => 1.hour.ago.utc.iso8601 }
    ))

    stub_search(issue: [
      item(number: 5, repo: "tadasant/strad", created_at: 2.hours.ago),
      item(number: 900, created_at: STALE_AGE.ago)
    ]) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  test "an issue the poller already fired at the cursor's second is not a stall" do
    fired_at = Time.iso8601("2026-07-01T00:00:00Z")
    @issue_condition.update!(configuration: @issue_condition.configuration.merge(
      "seen_issue_keys" => [ "tadasant/zimmer#7" ]
    ))
    ErrorReporter.expects(:report_message).never

    stub_search(issue: [ item(number: 7, created_at: fired_at) ]) do
      GithubTriggerHealthCheckJob.perform_now
    end
  end

  # ── Failure handling ───────────────────────────────────────────────────────

  test "a search failure checking one condition is logged at info and does not abort the sweep" do
    ErrorReporter.expects(:report_message).never
    GithubSearchService.stubs(:search_issues).raises(GithubSearchService::SearchError, "upstream refused")

    entries = capture_log_entries { assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now } }

    assert entries.none? { |severity, _| severity == "ERROR" }, "a failed probe must not page"
    infos = entries.select { |severity, message| severity == "INFO" && message.include?("Could not check condition") }
    assert_equal 2, infos.size, "both conditions were attempted; neither aborted the other"
  end

  test "a rate limit stops the run rather than spending more of the quota that caused it" do
    ErrorReporter.expects(:report_message).never
    GithubSearchService.expects(:search_issues).once.raises(GithubSearchService::RateLimitedError, "429")

    assert_nothing_raised { GithubTriggerHealthCheckJob.perform_now }
  end

  # ── Placement ──────────────────────────────────────────────────────────────

  test "runs on default, not on the pollers queue it watches, as a singleton" do
    assert_equal "default", GithubTriggerHealthCheckJob.new.queue_name
    assert_equal 1, GithubTriggerHealthCheckJob.good_job_concurrency_config[:total_limit]
  end
end
