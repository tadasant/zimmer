# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubTriggerPollerJobTest < ActiveJob::TestCase
  setup do
    @label_condition = trigger_conditions(:github_label_condition)
    @issue_condition = trigger_conditions(:github_issue_condition)
    # perform preflights `gh auth status` via GithubSearchService.configured?. Default it
    # to configured so the behavioral tests below exercise the polling path rather than the
    # graceful-degradation early return; the unconfigured path has its own tests.
    GithubSearchService.stubs(:configured?).returns(true)
  end

  # An item shaped like the search-API fields the poller actually reads.
  def item(number:, labels: [], repo: "tadasant/zimmer", created_at: "2026-07-10T12:00:00Z", pr: true)
    {
      "number" => number,
      "title" => "Item #{number}",
      "html_url" => "https://github.com/#{repo}/#{pr ? 'pull' : 'issues'}/#{number}",
      "repository_url" => "https://api.github.com/repos/#{repo}",
      "user" => { "login" => "someone" },
      "body" => "body of #{number}",
      "labels" => labels.map { |name| { "name" => name } },
      "created_at" => created_at,
      "pull_request" => pr ? { "url" => "x" } : nil
    }.compact
  end

  # Stubs GithubSearchService.search_issues, dispatching on the query rather than on call
  # order: both enabled GitHub conditions are polled every run and fixture ids are hashed,
  # so the order the poller visits them in is not something a test may rely on.
  #
  # A github_issue query starts with "is:issue "; a github_label query always starts with
  # "is:open " (whether it targets PRs or issues), so the two never collide.
  def stub_search(label: [], issue: [])
    queries = []
    fake = lambda do |query, **_opts|
      queries << query
      query.start_with?("is:issue ") ? issue : label
    end

    GithubSearchService.stub(:search_issues, fake) { yield queries }
  end

  # ── github_label: turning state into an event ─────────────────────────────

  test "first poll baselines already-labelled items and fires nothing" do
    # A never-polled condition has no seen_items key at all — absent, not empty.
    @label_condition.update_column(:configuration, @label_condition.configuration.except("seen_items"))
    assert_not @label_condition.reload.github_baselined?

    stub_search(label: [ item(number: 1, labels: [ "ready to merge" ]) ]) do
      assert_no_difference "Session.count" do
        GithubTriggerPollerJob.perform_now
      end
    end

    @label_condition.reload
    assert @label_condition.github_baselined?
    assert_equal [ "tadasant/zimmer#1:ready to merge" ], @label_condition.github_seen_items
    assert_nil @label_condition.last_triggered_at
  end

  test "a newly labelled item fires exactly once and does not re-fire while it keeps the label" do
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    stub_search(label: labelled) do
      assert_difference "Session.count", 1 do
        GithubTriggerPollerJob.perform_now
      end
    end

    @label_condition.reload
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.github_seen_items
    assert_not_nil @label_condition.last_triggered_at

    # Same item, same label, still open: already in the seen-set, so no second session.
    stub_search(label: labelled) do
      assert_no_difference "Session.count" do
        GithubTriggerPollerJob.perform_now
      end
    end

    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "removing and re-adding a label fires again" do
    stub_search(label: [ item(number: 7, labels: [ "ready to merge" ]) ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    # Label removed: the item leaves the search, so it leaves the seen-set.
    stub_search(label: []) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [], @label_condition.reload.github_seen_items

    # Re-added: the key is new again.
    stub_search(label: [ item(number: 7, labels: [ "ready to merge" ]) ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "an item carrying only unwatched labels does not fire" do
    stub_search(label: [ item(number: 9, labels: [ "bug" ]) ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    assert_equal [], @label_condition.reload.github_seen_items
  end

  test "each watched label added to one item is its own event" do
    @label_condition.update!(configuration: @label_condition.configuration.merge(
      "labels" => [ "ready to merge", "urgent" ]
    ))
    # Editing the watched labels re-baselines, so re-establish an empty baseline first.
    @label_condition.update!(configuration: @label_condition.configuration.merge("seen_items" => []))

    stub_search(label: [ item(number: 5, labels: [ "ready to merge", "urgent" ]) ]) do
      assert_difference("Session.count", 2) { GithubTriggerPollerJob.perform_now }
    end

    assert_equal(
      [ "tadasant/zimmer#5:ready to merge", "tadasant/zimmer#5:urgent" ],
      @label_condition.reload.github_seen_items
    )
  end

  test "an item whose session could not be created is retried on the next tick" do
    labelled = [ item(number: 3, labels: [ "ready to merge" ]) ]

    Trigger.any_instance.stubs(:create_session!).raises(StandardError, "boom")
    stub_search(label: labelled) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    # Never recorded as seen, so it is still "new" next time.
    assert_equal [], @label_condition.reload.github_seen_items

    Trigger.any_instance.unstub(:create_session!)
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#3:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "label query batches every watched repo and label into one request" do
    @label_condition.update!(configuration: @label_condition.configuration.merge(
      "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ],
      "labels" => [ "ready to merge", "urgent" ]
    ))

    stub_search do |queries|
      GithubTriggerPollerJob.perform_now

      label_queries = queries.select { |q| q.start_with?("is:open ") }
      assert_equal 1, label_queries.length, "expected all repos in a single request"
      assert_equal(
        "is:open is:pr (repo:tadasant/zimmer OR repo:tadasant/zimmer-catalog) " \
        '(label:"ready to merge" OR label:"urgent")',
        label_queries.first
      )
    end
  end

  test "target issue searches issues rather than pull requests" do
    @label_condition.update!(configuration: @label_condition.configuration.merge("target" => "issue"))

    stub_search do |queries|
      GithubTriggerPollerJob.perform_now
      assert queries.any? { |q| q.start_with?("is:open is:issue ") },
             "expected an is:issue label query, got #{queries.inspect}"
    end
  end

  test "conditions on disabled triggers are not polled" do
    disabled = trigger_conditions(:disabled_github_label_condition)

    stub_search(label: [ item(number: 1, labels: [ "ready to merge" ]) ]) do |queries|
      GithubTriggerPollerJob.perform_now
      # Only the two enabled GitHub conditions issued a query.
      assert_equal 2, queries.length
    end

    assert_nil disabled.reload.last_triggered_at
  end

  test "a search failure alerts and leaves the condition's state untouched" do
    before = @label_condition.github_seen_items

    AlertService.stubs(:raise_alert)
    GithubSearchService.stub(:search_issues, ->(*, **) { raise GithubSearchService::SearchError, "rate limited" }) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    assert_equal before, @label_condition.reload.github_seen_items
  end

  # ── Graceful degradation when gh is unauthenticated ───────────────────────
  #
  # An environment whose worker has no gh credential (observed on staging: every tick
  # failed with "please run: gh auth login") must not shell out per condition and alert
  # per failure every minute. The poller preflights GithubSearchService.configured? and
  # skips the whole tick when it is false — the same shape as SlackTriggerPollerJob's
  # `return unless SlackService.configured?`. This is deliberately distinct from a
  # transient API failure on a CONFIGURED host, which still raises and alerts (above).

  test "skips the tick without searching or alerting when gh is not authenticated" do
    GithubSearchService.stubs(:configured?).returns(false)
    GithubSearchService.expects(:search_issues).never
    AlertService.expects(:raise_alert).never

    before_label = @label_condition.github_seen_items
    before_issue = @issue_condition.github_last_issue_at

    assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }

    # State is untouched — a missing credential is not a poll, so nothing advances.
    assert_equal before_label, @label_condition.reload.github_seen_items
    assert_equal before_issue, @issue_condition.reload.github_last_issue_at
  end

  test "does not preflight gh auth at all when there are no GitHub conditions to poll" do
    # The common instance has no GitHub triggers; it must not spend a `gh auth status`
    # subprocess every minute for nothing.
    Trigger.with_github_conditions.destroy_all

    GithubSearchService.expects(:configured?).never
    GithubSearchService.expects(:search_issues).never

    assert_nothing_raised { GithubTriggerPollerJob.perform_now }
  end

  # ── github_issue: created_at cursor ───────────────────────────────────────

  test "first poll of a new-issue condition baselines the cursor and fires nothing" do
    @issue_condition.update_column(
      :configuration,
      @issue_condition.configuration.except("last_issue_at", "seen_issue_keys")
    )

    stub_search(issue: [ item(number: 1, pr: false) ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    @issue_condition.reload
    assert_not_nil @issue_condition.github_last_issue_at
    assert_equal [], @issue_condition.github_seen_issue_keys
  end

  test "a new issue fires once and advances the cursor past it" do
    fresh = item(number: 42, pr: false, created_at: "2026-07-12T09:00:00Z")

    stub_search(issue: [ fresh ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    @issue_condition.reload
    assert_equal "2026-07-12T09:00:00Z", @issue_condition.github_last_issue_at
    assert_equal [ "tadasant/zimmer#42" ], @issue_condition.github_seen_issue_keys

    # The cursor is inclusive, so the same issue comes back next tick; the key set is
    # what stops it from firing twice.
    stub_search(issue: [ fresh ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
  end

  test "two issues created in the same second both fire and are both remembered" do
    # GitHub's created: qualifier has second granularity, so the cursor alone cannot
    # separate these two — only the companion key set can.
    a = item(number: 50, pr: false, created_at: "2026-07-12T09:00:00Z")
    b = item(number: 51, pr: false, created_at: "2026-07-12T09:00:00Z")

    stub_search(issue: [ a, b ]) do
      assert_difference("Session.count", 2) { GithubTriggerPollerJob.perform_now }
    end

    @issue_condition.reload
    assert_equal "2026-07-12T09:00:00Z", @issue_condition.github_last_issue_at
    assert_equal [ "tadasant/zimmer#50", "tadasant/zimmer#51" ], @issue_condition.github_seen_issue_keys

    stub_search(issue: [ a, b ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
  end

  test "new-issue query scopes to issues in the watched repos around the cursor" do
    stub_search do |queries|
      GithubTriggerPollerJob.perform_now
      query = queries.find { |q| q.start_with?("is:issue ") }
      # Cursor is 2026-07-01T00:00:00Z; the window opens INDEX_LAG_GRACE (30m) earlier so a
      # late-indexed issue behind the cursor is still caught. See the index-lag test below.
      assert_equal "is:issue (repo:tadasant/zimmer) created:>=2026-06-30T23:30:00Z", query
    end
  end

  # ── The payload handed to the session ─────────────────────────────────────

  test "the prompt carries repo, number and link when the template uses the variables" do
    stub_search(label: [ item(number: 77, labels: [ "ready to merge" ]) ]) do
      GithubTriggerPollerJob.perform_now
    end

    prompt = Session.order(:created_at).last.prompt
    assert_includes prompt, "tadasant/zimmer#77"
    assert_includes prompt, "https://github.com/tadasant/zimmer/pull/77"
    assert_includes prompt, "label added: ready to merge"
  end

  test "a template naming no GitHub variable still receives the item as a context block" do
    # github_issue_trigger's template is plain prose ("Triage this issue.").
    stub_search(issue: [ item(number: 88, pr: false, created_at: "2026-07-12T09:00:00Z") ]) do
      GithubTriggerPollerJob.perform_now
    end

    prompt = Session.order(:created_at).last.prompt
    assert_includes prompt, "Triage this issue."
    assert_includes prompt, "**Repository:** tadasant/zimmer"
    assert_includes prompt, "**Number:** #88"
    assert_includes prompt, "https://github.com/tadasant/zimmer/issues/88"
  end

  # ── Regressions caught in review ──────────────────────────────────────────

  test "a label typed in the wrong case still matches — GitHub label search is case-insensitive" do
    # GitHub's `label:` qualifier ignores case, so the search returns the item; an exact-string
    # filter here would discard it and the condition would silently never fire.
    @label_condition.update!(configuration: @label_condition.configuration.merge(
      "labels" => [ "Ready To Merge" ]
    ))
    @label_condition.update!(configuration: @label_condition.configuration.merge("seen_items" => []))

    stub_search(label: [ item(number: 12, labels: [ "ready to merge" ]) ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    # Keyed by the CONFIGURED casing, so the key is stable across ticks.
    assert_equal [ "tadasant/zimmer#12:Ready To Merge" ], @label_condition.reload.github_seen_items

    stub_search(label: [ item(number: 12, labels: [ "ready to merge" ]) ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
  end

  test "a dropped follow-up does not count as a fire, so the item is retried" do
    # A reuse_session trigger whose target session is busy returns the session truthily but
    # drops the prompt. Recording that as seen would consume the event and do no work.
    labelled = [ item(number: 21, labels: [ "ready to merge" ]) ]
    session = sessions(:active_session)
    Trigger.any_instance.stubs(:create_session!).returns(session)
    Trigger.any_instance.stubs(:last_follow_up_dropped?).returns(true)

    stub_search(label: labelled) do
      GithubTriggerPollerJob.perform_now
    end
    assert_equal [], @label_condition.reload.github_seen_items,
                 "a dropped follow-up must leave the item unseen so the next tick retries it"

    Trigger.any_instance.unstub(:last_follow_up_dropped?)
    Trigger.any_instance.unstub(:create_session!)
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#21:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "an issue indexed late is still fired, not jumped over by the cursor" do
    # GitHub's search index is eventually consistent AND unordered: of two issues opened
    # seconds apart, the newer can be indexed first. A bare `created:>=cursor` would fire the
    # newer, advance past it, and never see the older one.
    older = item(number: 60, pr: false, created_at: "2026-07-12T09:00:10Z")
    newer = item(number: 61, pr: false, created_at: "2026-07-12T09:00:40Z")

    # Tick 1: only the NEWER issue is indexed yet.
    stub_search(issue: [ newer ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal "2026-07-12T09:00:40Z", @issue_condition.reload.github_last_issue_at

    # Tick 2: the older issue finally appears. It is BEHIND the cursor, but inside the
    # lag-grace window, so it still fires — exactly once.
    stub_search(issue: [ older, newer ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    prompt = Session.order(:created_at).last.prompt
    assert_includes prompt, "tadasant/zimmer/issues/60"

    # Tick 3: both are known. Nothing re-fires.
    stub_search(issue: [ older, newer ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
  end

  test "the issue query reaches back behind the cursor to absorb index lag" do
    stub_search do |queries|
      GithubTriggerPollerJob.perform_now
      query = queries.find { |q| q.start_with?("is:issue ") }
      # Cursor is 2026-07-01T00:00:00Z; the window opens INDEX_LAG_GRACE earlier.
      assert_includes query, "created:>=2026-06-30T23:30:00Z"
    end
  end

  test "state computed against a stale scope is discarded when the condition is re-scoped mid-tick" do
    # Simulate a UI edit landing while the tick is in flight: the search returns items for the
    # OLD scope, but by the time we write, the user has re-scoped (and thus re-baselined).
    condition_id = @label_condition.id
    GithubSearchService.stub(:search_issues, lambda { |query, **_|
      next [] unless query.start_with?("is:open ")
      TriggerCondition.find(condition_id).update!(
        configuration: { "repos" => [ "tadasant/zimmer", "tadasant/other" ],
                         "target" => "pull_request", "labels" => [ "ready to merge" ] }
      )
      [ item(number: 30, labels: [ "ready to merge" ]) ]
    }) do
      GithubTriggerPollerJob.perform_now
    end

    @label_condition.reload
    assert_equal [ "tadasant/zimmer", "tadasant/other" ].sort, @label_condition.github_repos.sort,
                 "the user's edit must survive the poller's write"
    assert_not @label_condition.github_baselined?,
               "the re-baseline requested by the edit must not be undone by the in-flight tick"
  end

  test "a template that names only Slack-shared variables still gets a GitHub context block" do
    # {{text}} is also a Slack variable, so it does not identify which PR this is.
    @label_condition.trigger.update!(prompt_template: "Look at this: {{text}}")

    stub_search(label: [ item(number: 99, labels: [ "ready to merge" ]) ]) do
      GithubTriggerPollerJob.perform_now
    end

    prompt = Session.order(:created_at).last.prompt
    assert_includes prompt, "**Number:** #99"
    assert_includes prompt, "https://github.com/tadasant/zimmer/pull/99"
  end

  # ── The rescue must not hide a broken poller ──────────────────────────────
  #
  # `perform` rescues per-condition errors into an alert. That is right for a transient
  # GitHub failure, but it means an exception raised on EVERY condition — an arity error,
  # a typo, a nil — is invisible to any test that only asserts a negative ("no session was
  # created"), because a poller that raises creates no sessions either.
  #
  # A braceless `write_state(condition, scope, "seen_items" => ...)` shipped exactly that
  # way: under Ruby 3's kwarg separation the trailing string-keyed hash is swept into the
  # keyword hash, leaving 2 positional args for 3 required params, and every tick died with
  # "wrong number of arguments (given 2, expected 3)".
  #
  # These tests drive process_condition DIRECTLY, outside the rescue, so any exception
  # propagates and fails with its real message. Crucially they cover EVERY write_state call
  # site — the first-poll/baseline branch and the steady-state branch are *different* calls,
  # and a test that only exercises a baselined condition never reaches the baseline one.

  # Strips the poller-owned keys, putting a condition back in its never-polled state so the
  # first-poll branch is the one that runs.
  def un_baseline!(condition)
    condition.update_column(
      :configuration,
      condition.configuration.except("seen_items", "last_issue_at", "seen_issue_keys")
    )
    condition.reload
  end

  test "process_condition drives a github_label condition through both write paths without raising" do
    job = GithubTriggerPollerJob.new
    labelled = [ item(number: 5, labels: [ "ready to merge" ]) ]

    # 1. First poll — the BASELINE write path.
    un_baseline!(@label_condition)
    GithubSearchService.stub(:search_issues, ->(*, **) { labelled }) do
      assert_nothing_raised { job.send(:process_condition, @label_condition) }
    end
    assert_equal [ "tadasant/zimmer#5:ready to merge" ], @label_condition.reload.github_seen_items

    # 2. Second poll — the STEADY-STATE write path (a different write_state call site).
    GithubSearchService.stub(:search_issues, ->(*, **) { labelled }) do
      assert_nothing_raised { job.send(:process_condition, @label_condition) }
    end
    assert_equal [ "tadasant/zimmer#5:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "process_condition drives a github_issue condition through both write paths without raising" do
    job = GithubTriggerPollerJob.new
    issue = [ item(number: 6, pr: false, created_at: "2026-07-12T09:00:00Z") ]

    # 1. First poll — the BASELINE write path (sets the cursor, fires nothing).
    un_baseline!(@issue_condition)
    GithubSearchService.stub(:search_issues, ->(*, **) { issue }) do
      assert_nothing_raised { job.send(:process_condition, @issue_condition) }
    end
    assert_not_nil @issue_condition.reload.github_last_issue_at

    # 2. Wind the cursor back so the next poll sees the issue as new, exercising the
    #    STEADY-STATE write path.
    @issue_condition.update!(configuration: @issue_condition.configuration.merge(
      "last_issue_at" => "2026-07-12T08:00:00Z", "seen_issue_keys" => []
    ))
    GithubSearchService.stub(:search_issues, ->(*, **) { issue }) do
      assert_nothing_raised { job.send(:process_condition, @issue_condition) }
    end
    assert_equal "2026-07-12T09:00:00Z", @issue_condition.reload.github_last_issue_at
  end

  test "a poll of both condition types never reaches the alert path, on first poll or steady state" do
    # If any condition raises, perform's rescue calls AlertService.raise_alert. Asserting it
    # is never called is what turns a swallowed exception into a test failure instead of
    # silence. Both conditions start un-baselined, so the first perform exercises the
    # baseline branches and the second the steady-state ones.
    AlertService.expects(:raise_alert).never

    un_baseline!(@label_condition)
    un_baseline!(@issue_condition)

    label_items = [ item(number: 8, labels: [ "ready to merge" ]) ]
    issue_items = [ item(number: 9, pr: false, created_at: "2026-07-12T10:00:00Z") ]

    # Poll 1 — the baseline branches.
    stub_search(label: label_items, issue: issue_items) do
      GithubTriggerPollerJob.perform_now
    end

    # A new-issue condition baselines its cursor to NOW and fires nothing, so the fixture
    # issue is history to it. Wind the cursor back so poll 2 genuinely has work to do and
    # exercises the steady-state branch rather than short-circuiting on an empty result.
    @issue_condition.update!(configuration: @issue_condition.configuration.merge(
      "last_issue_at" => "2026-07-12T08:00:00Z", "seen_issue_keys" => []
    ))

    # Poll 2 — the steady-state branches.
    stub_search(label: label_items, issue: issue_items) do
      GithubTriggerPollerJob.perform_now
    end

    # Both paths actually did their work, so the expectation above is not vacuous.
    assert_equal [ "tadasant/zimmer#8:ready to merge" ], @label_condition.reload.github_seen_items
    assert_equal "2026-07-12T10:00:00Z", @issue_condition.reload.github_last_issue_at
  end
end
