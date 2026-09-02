# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Every class in this file drives GithubTriggerPollerJob#perform, which preflights
# `gh auth status` through GithubSearchService.auth_preflight before it polls anything.
# Each therefore has to stub that preflight in setup, or every test in it silently
# exercises the graceful-degradation early return instead of the polling path.
module GithubTriggerPollerPreflightStubs
  # Stands in for GithubSearchService.auth_preflight, which the poller reads to decide
  # whether to poll and — the point of #542 — what to say when it does not.
  def stub_preflight(state, detail = nil)
    GithubSearchService.stubs(:auth_preflight)
      .returns(GithubSearchService::PreflightResult.new(state, detail))
  end

  # The poller's WARN lines for one tick.
  def capture_warns(&block)
    capture_log_entries(&block).filter_map do |severity, message|
      message if severity == "WARN" && message.start_with?("[GithubTriggerPollerJob]")
    end
  end
end

class GithubTriggerPollerJobTest < ActiveJob::TestCase
  include GithubTriggerPollerPreflightStubs

  setup do
    @label_condition = trigger_conditions(:github_label_condition)
    @issue_condition = trigger_conditions(:github_issue_condition)
    # Default the preflight to authenticated so the behavioral tests below exercise the
    # polling path rather than the early return; each failing state has its own tests.
    stub_preflight(GithubSearchService::PREFLIGHT_AUTHENTICATED)
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

  test "a labelled PR that transiently drops out of one search does not re-fire when it returns" do
    # The regression this whole grace mechanism exists for. GitHub's search index is eventually
    # consistent, so a still-open, still-labelled PR can be absent from one tick's results and
    # back on the next. Reading that single miss as a label removal drops the key and re-fires a
    # duplicate gate session — observed in production as `#106:ready to merge` firing while it
    # was already recorded in seen_items.
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items

    # One tick where the index fails to return the PR. It is NOT dropped, and nothing fires.
    stub_search(label: []) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items,
                 "a one-tick search blip must not drop the key from the seen-set"

    # The PR reappears. Because its key was retained, it is not new — so no duplicate session.
    stub_search(label: labelled) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "removing a label for the full grace window, then re-adding it, fires again" do
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    # The label is genuinely removed. The key survives the grace window — absent but held —
    # for REMOVAL_GRACE_TICKS - 1 ticks, so a real removal takes the full window to register.
    (GithubTriggerPollerJob::REMOVAL_GRACE_TICKS - 1).times do
      stub_search(label: []) do
        assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
      end
      assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items,
                   "the key must be held through the grace window, not dropped on first miss"
    end

    # The tick that reaches REMOVAL_GRACE_TICKS consecutive misses accepts the removal.
    stub_search(label: []) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [], @label_condition.reload.github_seen_items,
                 "after the grace window of sustained absence the key is dropped"

    # Re-added once the key has been dropped: it is new again, so it fires.
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "a miss streak resets the moment the label reappears, so a later removal gets the full grace" do
    # Guards against an off-by-one where a transient blip permanently "uses up" part of the
    # grace: after the PR reappears, a subsequent genuine removal must again get the full window.
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    # Blip, then back.
    stub_search(label: []) { GithubTriggerPollerJob.perform_now }
    stub_search(label: labelled) { GithubTriggerPollerJob.perform_now }
    assert_equal({}, @label_condition.reload.github_seen_missing_counts,
                 "reappearing must clear the miss streak")

    # A fresh removal still gets the full grace window before dropping.
    (GithubTriggerPollerJob::REMOVAL_GRACE_TICKS - 1).times do
      stub_search(label: []) { GithubTriggerPollerJob.perform_now }
      assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items
    end
    stub_search(label: []) { GithubTriggerPollerJob.perform_now }
    assert_equal [], @label_condition.reload.github_seen_items
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
    # Adding a label baselines what already carries it, so let one quiet tick take a
    # baseline that covers both labels before the real event arrives.
    stub_search(label: []) { GithubTriggerPollerJob.perform_now }

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

  # A GitHub item is durable state, unlike a broadcast event: leaving it unseen
  # costs nothing and gets the work done once the pending session is out of the way.
  test "an item skipped for a pending session is left unseen and fires on a later tick" do
    trigger = @label_condition.trigger
    trigger.update!(skip_if_pending_session: true)
    pending = sessions(:waiting)
    pending.update!(metadata: pending.metadata.merge("trigger_id" => trigger.id))

    labelled = [ item(number: 3, labels: [ "ready to merge" ]) ]

    stub_search(label: labelled) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [], @label_condition.reload.github_seen_items

    pending.update_columns(status: Session.statuses[:archived])
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#3:ready to merge" ], @label_condition.reload.github_seen_items
  end

  # ── #704: one label event, one session — even when the fire falls over ────
  #
  # Trigger 352 spawned TWO merge-gate sessions for one `ready to merge` label,
  # 55s and 43s apart, on 2026-08-29. Both pairs are consecutive poller ticks, and
  # the poller cannot run twice at once (GoodJob `total_limit: 1`), so the second
  # session means the FIRST tick's bookkeeping did not record a key whose session
  # already existed. Two ways that happens, both covered here.
  #
  # The opposite failure is the worse one — #647 is a real label event swallowed —
  # so every case below has its mirror: an item that genuinely produced no session
  # must still be left unseen for the next tick to retry.

  test "an item whose session was created but whose fire then failed is not spawned for twice" do
    # The mechanism behind #704. Session.create_from_agent_root! commits the session
    # row and THEN enqueues its one AgentSessionJob; Trigger#create_session! keeps
    # working after that. A raise anywhere in there used to unwind out of #fire as
    # "no session was created", leaving the key unseen for the next tick to re-fire.
    # That is session 10426 (created, never dispatched) and its sibling 10427.
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    AgentSessionJob.stubs(:enqueue_new_session).raises(RuntimeError, "the agents queue is unreachable")
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    AgentSessionJob.unstub(:enqueue_new_session)

    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items,
                 "a session exists for this label, so the event is consumed even though the fire raised"

    # The next tick, sixty seconds later. Without the fix this is where the duplicate
    # gate session was born.
    stub_search(label: labelled) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
  end

  test "a fired key survives a lost end-of-tick state write and is not spawned for twice" do
    # The other route to the same duplicate: the fire succeeded outright, and the
    # single write that was supposed to remember it never landed. Every key fired in
    # that tick used to come back as new.
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    AlertService.stubs(:raise_alert)
    GithubTriggerPollerJob.any_instance.stubs(:write_state).raises(RuntimeError, "the state write was lost")
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    GithubTriggerPollerJob.any_instance.unstub(:write_state)

    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items,
                 "the key is recorded the instant its session exists, not only at the end of the tick"
    assert_not_nil @label_condition.reload.last_triggered_at,
                   "last_triggered_at rides along with the state it belongs to"

    stub_search(label: labelled) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
  end

  test "an item that produced no session at all is left unseen for the next tick" do
    # #647's direction. The guard above must key on "does a session exist", not on
    # "did the fire raise" — a fire that fell over BEFORE creating anything is a
    # dropped event, and dropping a `ready to merge` label silently is the failure
    # that leaves a PR waiting forever with nobody to notice.
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    Trigger.any_instance.stubs(:create_session!).raises(RuntimeError, "the catalog would not resolve")
    stub_search(label: labelled) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    Trigger.any_instance.unstub(:create_session!)

    assert_equal [], @label_condition.reload.github_seen_items,
                 "no session was created, so the label must still look new"

    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
  end

  test "a fire that fails before spawning does not inherit the previous item's session" do
    # The trap in keying on Trigger#last_fire_created_session: both items in a tick
    # share one in-memory Trigger, so a raise BEFORE #create_session! is entered would
    # read the marker the previous item left and record an item that has no session.
    # #7 sorts before #8, so the first interpolation is #7's and the second is #8's.
    two = [ item(number: 7, labels: [ "ready to merge" ]), item(number: 8, labels: [ "ready to merge" ]) ]

    Trigger.any_instance.stubs(:interpolate_prompt)
      .returns("rate this PR").then.raises(RuntimeError, "the prompt template blew up")

    stub_search(label: two) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    Trigger.any_instance.unstub(:interpolate_prompt)

    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items,
                 "#8 never reached a spawn, so it must not be credited with #7's session"

    # And it really does retry, rather than being lost.
    stub_search(label: two) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#7:ready to merge", "tadasant/zimmer#8:ready to merge" ],
                 @label_condition.reload.github_seen_items
  end

  test "the per-fire write leaves the documented remove-then-re-label semantics intact" do
    # An end-to-end guard rather than a discriminating one: a key cannot be both
    # newly-fired and in the removal path in the same tick, so #record_fired_key is
    # never invoked on the ticks that expire the grace. What it pins is the property
    # that matters to #647 — that adding a durability floor under `seen_items` did not
    # quietly make a genuine re-label stop firing.
    labelled = [ item(number: 7, labels: [ "ready to merge" ]) ]

    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    GithubTriggerPollerJob::REMOVAL_GRACE_TICKS.times do
      stub_search(label: []) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [], @label_condition.reload.github_seen_items

    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
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

  test "a nil gh status is surfaced as a SearchError alert, not a NoMethodError crash" do
    # End-to-end reproduction of prod incident 2026-07-19 (condition 352): the real
    # GithubSearchService.request path runs, but BoundedSubprocess returns a nil
    # Process::Status (Open3's detach-thread #value is nil when the child was reaped
    # before its own waitpid). Before the fix, `status.success?` raised
    # `undefined method 'success?' for nil`; the per-condition rescue caught it but
    # reported that scary NoMethodError. It must instead flow through the normal gh-failure
    # path — a SearchError the rescue turns into one alert and a retry next tick — and never
    # touch the condition's seen-set.
    BoundedSubprocess.stubs(:run).returns([ "", "", nil ])

    # The gh failure rides on error: (rendered into the alert's log snippet)
    # rather than being hand-copied into details.
    snippets = []
    AlertService.stubs(:raise_alert).with do |*args, **kwargs|
      opts = kwargs.empty? ? (args.last.is_a?(Hash) ? args.last : {}) : kwargs
      snippets << AlertSnippet.build(opts[:error]).to_s
      true
    end

    before = @label_condition.github_seen_items
    assert_nothing_raised { GithubTriggerPollerJob.perform_now }

    assert snippets.any?, "expected the nil gh status to raise a per-condition alert"
    assert snippets.all? { |s| s.include?("gh api search/issues failed") },
           "alert should describe the gh failure, got: #{snippets.inspect}"
    assert snippets.none? { |s| s.include?("undefined method") },
           "a nil status must not escape as a NoMethodError, got: #{snippets.inspect}"
    assert_equal before, @label_condition.reload.github_seen_items
  end

  test "an incomplete search index skips the condition quietly instead of paging" do
    # Production 2026-08-10, condition 352: GitHub's search index timed out once, the
    # search refused the short read (correctly — see the service test), and the refusal
    # paged a human at 23:14 for a failure that had already healed by the next tick. The
    # refusal stays; the page goes. Both routes to #eng-alerts must be silent: AlertService,
    # and a plain Rails.logger.error line (which pages on its own via the Grafana rule).
    before = @label_condition.github_seen_items
    AlertService.expects(:raise_alert).never
    Rails.logger.expects(:error).never

    incomplete = lambda do |query, **_opts|
      raise GithubSearchService::IncompleteResultsError,
            "GitHub search returned incomplete results for query: #{query}"
    end

    GithubSearchService.stub(:search_issues, incomplete) do
      assert_no_difference("Session.count") { assert_nothing_raised { GithubTriggerPollerJob.perform_now } }
    end

    # The seen-set is untouched, which is the whole point of refusing the partial read:
    # nothing was dropped from it, so nothing re-fires when the next tick succeeds.
    assert_equal before, @label_condition.reload.github_seen_items
  end

  # ── Graceful degradation when gh is unauthenticated ───────────────────────
  #
  # An environment whose worker has no gh credential (observed on staging: every tick
  # failed with "please run: gh auth login") must not shell out per condition and alert
  # per failure every minute. The poller preflights GithubSearchService.auth_preflight and
  # skips the whole tick unless it authenticated — the same shape as SlackTriggerPollerJob's
  # `return unless SlackService.configured?`. This is deliberately distinct from a
  # transient API failure on a CONFIGURED host, which still raises and alerts (above).

  test "skips the tick without searching or alerting when gh is not authenticated" do
    stub_preflight(GithubSearchService::PREFLIGHT_UNCONFIGURED, "no github.com credential is configured")
    GithubSearchService.expects(:search_issues).never
    AlertService.expects(:raise_alert).never

    before_label = @label_condition.github_seen_items
    before_issue = @issue_condition.github_last_issue_at

    assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }

    # State is untouched — a missing credential is not a poll, so nothing advances.
    assert_equal before_label, @label_condition.reload.github_seen_items
    assert_equal before_issue, @issue_condition.reload.github_last_issue_at
  end

  test "an unconfigured host keeps the original WARN verbatim" do
    # The staging line must not change. It is the one state that was always accurate,
    # and an operator (and any log filter built on it) should see exactly what they did.
    stub_preflight(GithubSearchService::PREFLIGHT_UNCONFIGURED, "no github.com credential is configured")

    logged = capture_warns { GithubTriggerPollerJob.perform_now }

    assert_equal 1, logged.length, "one WARN per tick, as before"
    assert_equal "[GithubTriggerPollerJob] gh CLI is not authenticated (no gh auth login / GH_TOKEN); " \
                 "skipping GitHub trigger polling this tick", logged.first
  end

  # ── #542: a GitHub degradation must not be reported as a missing credential ──
  #
  # The defect this replaces: during the 2026-08-17 REST degradation the preflight
  # failed against a credential that was valid minutes either side, and the poller
  # announced "gh CLI is not authenticated (no gh auth login / GH_TOKEN)" — sending an
  # operator to check a credential that was fine, in text byte-identical to a revoked
  # token's. The skip itself is unchanged (removing it brings back staging's alert
  # storm); what must differ is what the line SAYS.
  test "a preflight that could not reach GitHub does not claim the credential is missing" do
    stub_preflight(GithubSearchService::PREFLIGHT_UNKNOWN,
                   "Get \"https://api.github.com/\": Service Unavailable")
    GithubSearchService.expects(:search_issues).never
    AlertService.expects(:raise_alert).never

    logged = capture_warns { GithubTriggerPollerJob.perform_now }
    line = logged.sole

    assert_not_includes line, "gh CLI is not authenticated",
                        "the whole defect: a reachability failure must not read as a missing credential"
    assert_not_includes line, "no gh auth login / GH_TOKEN"
    assert_includes line, "could not reach GitHub"
    assert_includes line, "UNKNOWN"
    assert_includes line, "Service Unavailable", "gh's own words, so the operator can see what happened"
    assert_includes line, "githubstatus.com"
    assert_includes line, "skipping GitHub trigger polling this tick", "the early return survives"
  end

  test "a rejected credential says so, distinctly from both of the others" do
    stub_preflight(GithubSearchService::PREFLIGHT_REJECTED,
                   "non-200 OK status code: 401 Unauthorized body: Bad credentials")

    line = capture_warns { GithubTriggerPollerJob.perform_now }.sole

    assert_includes line, "GitHub rejected the gh credential"
    assert_includes line, "needs rotating"
    assert_not_includes line, "could not reach GitHub"
  end

  test "the three preflight failures are distinguishable from the logs alone" do
    # The acceptance criterion for #542 stated directly: an operator reading a single
    # line must be able to tell which of the three happened, at the moment it happens.
    lines = [
      [ GithubSearchService::PREFLIGHT_UNCONFIGURED, "no github.com credential is configured" ],
      [ GithubSearchService::PREFLIGHT_REJECTED, "non-200 OK status code: 401 Unauthorized" ],
      [ GithubSearchService::PREFLIGHT_UNKNOWN, "Get \"https://api.github.com/\": Service Unavailable" ]
    ].map do |state, detail|
      stub_preflight(state, detail)
      capture_warns { GithubTriggerPollerJob.perform_now }.sole
    end

    assert_equal 3, lines.uniq.length, "each preflight failure must produce a different line"
  end

  test "no preflight failure alerts, whatever its cause" do
    # Deliberate: a preflight failure is the TOTAL case, and the total case is reported
    # by the stale heartbeat (GithubTriggerHealthCheckJob), exactly as #skip_incomplete_search
    # reasons about a broadly degraded search API. Paging here would page for every blip
    # and would put an alert back on the path whose storm the early return exists to stop.
    [ GithubSearchService::PREFLIGHT_UNCONFIGURED,
      GithubSearchService::PREFLIGHT_REJECTED,
      GithubSearchService::PREFLIGHT_UNKNOWN ].each do |state|
      stub_preflight(state, "detail")
      AlertService.expects(:raise_alert).never

      GithubTriggerPollerJob.perform_now
    end
  end

  test "does not preflight gh auth at all when there are no GitHub conditions to poll" do
    # The common instance has no GitHub triggers; it must not spend a `gh auth status`
    # subprocess every minute for nothing.
    Trigger.with_github_conditions.destroy_all

    GithubSearchService.unstub(:auth_preflight)
    GithubSearchService.expects(:auth_preflight).never
    GithubSearchService.expects(:search_issues).never

    assert_nothing_raised { GithubTriggerPollerJob.perform_now }
  end

  # ── github_label: editing a live condition (#647) ─────────────────────────
  #
  # The incident: a `repos` edit on the merge gate's condition dropped the seen-set, and
  # the next tick recorded every currently-labelled PR as seen while firing for none of
  # them. A PR labelled a minute after the edit was absorbed and never got a session —
  # permanently, because it was now in the seen-set. These cover both directions of the
  # fix: the events in the repos that were already watched still fire, and the ones in
  # the newly-watched repo still do not stampede.

  test "a PR labelled after a repos edit still fires" do
    # Tick 1 establishes the baseline and what it covers.
    stub_search(label: [ item(number: 7, labels: [ "ready to merge" ]) ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    # The edit, in the shape it was sent: the whole configuration read back and returned
    # with one key changed, poller state included verbatim.
    @label_condition.update!(configuration: @label_condition.reload.configuration.merge(
      "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ]
    ))
    assert @label_condition.reload.github_baselined?,
           "an edit must not cost a live condition its seen-set"

    # A minute later, a PR in the repo that was already being watched gains the label.
    labelled = [
      item(number: 7, labels: [ "ready to merge" ]),
      item(number: 9, labels: [ "ready to merge" ])
    ]
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    assert_includes @label_condition.reload.github_seen_items, "tadasant/zimmer#9:ready to merge"
  end

  test "adding a repo baselines the PRs already labelled in it instead of stampeding sessions" do
    stub_search(label: []) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    @label_condition.update!(configuration: @label_condition.reload.configuration.merge(
      "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ]
    ))

    # Three PRs that have carried the label in the new repo for weeks. Firing for them is
    # the opposite failure — on the merge gate, three gate sessions against PRs long since
    # handled — so they are absorbed, exactly as the condition's first tick absorbs them.
    already_labelled = (1..3).map do |n|
      item(number: n, labels: [ "ready to merge" ], repo: "tadasant/zimmer-catalog")
    end
    stub_search(label: already_labelled) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    assert_equal already_labelled.map { |i| "tadasant/zimmer-catalog##{i['number']}:ready to merge" }.sort,
                 @label_condition.reload.github_seen_items

    # And the new repo is a first-class citizen from the next tick on.
    stub_search(label: already_labelled + [ item(number: 4, labels: [ "ready to merge" ], repo: "tadasant/zimmer-catalog") ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
  end

  test "adding a label baselines what already carries it while the original label keeps firing" do
    stub_search(label: []) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    @label_condition.update!(configuration: @label_condition.reload.configuration.merge(
      "labels" => [ "ready to merge", "needs review" ]
    ))

    labelled = [
      item(number: 11, labels: [ "needs review" ]),
      item(number: 12, labels: [ "ready to merge" ])
    ]
    stub_search(label: labelled) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    assert_equal [ "tadasant/zimmer#11:needs review", "tadasant/zimmer#12:ready to merge" ],
                 @label_condition.reload.github_seen_items
    # #12 is the one that fired: "ready to merge" was already being watched.
    assert_equal "https://github.com/tadasant/zimmer/pull/12", Session.order(:id).last.prompt[/https:\S+/]
  end

  test "flipping the target re-baselines the whole seen-set and fires nothing" do
    stub_search(label: [ item(number: 7, labels: [ "ready to merge" ]) ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    @label_condition.update!(configuration: @label_condition.reload.configuration.merge("target" => "issue"))

    # A repo numbers its issues and its PRs from one sequence, so #7 now means a different
    # item. The seen-set cannot be carried across that, and nothing fires on the tick that
    # rebuilds it.
    stub_search(label: [ item(number: 7, labels: [ "ready to merge" ], pr: false) ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items
    assert_equal "issue", @label_condition.github_baseline_scope["target"]
  end

  # Editing a condition is no longer a route to a lost seen-set, so one that has polled
  # before and comes back without it is an anomaly. It is still re-baselined
  # conservatively — the flood is the worse failure — but it stops being SILENT, which is
  # what makes the manual remedy (the trigger's `invoke`) reachable.
  test "a seen-set lost from a condition that has already polled alerts instead of absorbing in silence" do
    stub_search(label: []) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
    assert_not_nil @label_condition.reload.last_polled_at

    @label_condition.update_column(:configuration, @label_condition.configuration.except("seen_items"))

    AlertService.expects(:raise_alert).with do |title, options|
      title == "GitHub trigger baseline was reset" &&
        options[:details].include?("tadasant/zimmer#3:ready to merge") &&
        options[:dedup_key] == "github_trigger_baseline_reset_#{@label_condition.id}"
    end

    stub_search(label: [ item(number: 3, labels: [ "ready to merge" ]) ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    assert_equal [ "tadasant/zimmer#3:ready to merge" ], @label_condition.reload.github_seen_items
  end

  test "a first-ever baseline is silent — there is nothing to have lost" do
    un_baseline!(@label_condition)
    AlertService.expects(:raise_alert).never

    stub_search(label: [ item(number: 3, labels: [ "ready to merge" ]) ]) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end
  end

  # The compound case: a condition that has never had a scope stamped — which is every
  # live condition between this deploy and its first tick — and is widened in that
  # window. Reading its absent scope as "covers what is watched now" would make the
  # repo added a moment ago look already-baselined, and every PR labelled there for
  # weeks would fire. The pre-edit scope is stamped by the edit itself, so it does not.
  test "widening a condition that has no recorded baseline scope does not stampede its new repo" do
    assert_nil @label_condition.github_baseline_scope
    assert @label_condition.github_baselined?

    @label_condition.update!(configuration: @label_condition.configuration.merge(
      "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ]
    ))

    already_labelled = (1..3).map do |n|
      item(number: n, labels: [ "ready to merge" ], repo: "tadasant/zimmer-catalog")
    end
    stub_search(label: already_labelled + [ item(number: 7, labels: [ "ready to merge" ]) ]) do
      # Exactly one session: #7, in the repo that was already watched. The three in the
      # newly-added repo are baselined.
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    assert_equal "https://github.com/tadasant/zimmer/pull/7", Session.order(:id).last.prompt[/https:\S+/]
  end

  # A condition baselined before `baseline_scope` was recorded has none, and the deploy
  # that introduces the key must not make its whole result set look newly in scope.
  test "a seen-set with no recorded baseline scope keeps firing, and gets one stamped" do
    assert_nil @label_condition.github_baseline_scope

    stub_search(label: [ item(number: 7, labels: [ "ready to merge" ]) ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    assert_equal({ "repos" => [ "tadasant/zimmer" ], "target" => "pull_request",
                   "labels" => [ "ready to merge" ] },
                 @label_condition.reload.github_baseline_scope)
  end

  # ── github_issue: excluding issues by label ───────────────────────────────

  test "the issue query carries no negation when nothing is excluded" do
    stub_search(issue: []) do |queries|
      GithubTriggerPollerJob.perform_now

      issue_query = queries.find { |q| q.start_with?("is:issue ") }
      assert_equal "is:issue (repo:tadasant/zimmer) created:>=2026-06-30T23:30:00Z", issue_query
    end
  end

  test "each excluded label becomes a -label: negation in the issue query" do
    @issue_condition.update!(configuration: @issue_condition.configuration.merge(
      "exclude_labels" => [ "hold issue work gate", "wip" ]
    ))

    stub_search(issue: []) do |queries|
      GithubTriggerPollerJob.perform_now

      issue_query = queries.find { |q| q.start_with?("is:issue ") }
      assert_equal "is:issue (repo:tadasant/zimmer) created:>=2026-06-30T23:30:00Z " \
                   '-label:"hold issue work gate" -label:"wip"',
                   issue_query
    end
  end

  # The exclusion is applied by the SEARCH, so a held issue never reaches the poller at
  # all. What matters is that its absence does not look like progress: the cursor must not
  # advance past it, or removing the label later would leave it permanently unfired.
  test "a held-back issue neither fires nor moves the cursor" do
    @issue_condition.update!(configuration: @issue_condition.configuration.merge(
      "exclude_labels" => [ "hold issue work gate" ],
      "last_issue_at" => "2026-07-12T08:00:00Z",
      "seen_issue_keys" => []
    ))

    # GitHub returns nothing: the only issue opened in the window carries the label.
    stub_search(issue: []) do
      assert_no_difference("Session.count") { GithubTriggerPollerJob.perform_now }
    end

    @issue_condition.reload
    assert_equal "2026-07-12T08:00:00Z", @issue_condition.github_last_issue_at
    assert_equal [ "hold issue work gate" ], @issue_condition.github_exclude_labels
  end

  test "an unheld issue in an exclusion-carrying condition still fires" do
    @issue_condition.update!(configuration: @issue_condition.configuration.merge(
      "exclude_labels" => [ "hold issue work gate" ]
    ))

    stub_search(issue: [ item(number: 61, pr: false, created_at: "2026-07-12T09:00:00Z") ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end

    assert_equal "2026-07-12T09:00:00Z", @issue_condition.reload.github_last_issue_at
  end

  # ── github_issue: created_at cursor ───────────────────────────────────────

  # The github_issue half of #647. Its state is one global cursor with no per-repo
  # dimension, so a widened scope still re-baselines it — carrying the cursor across a
  # newly-added repo would back-fire every issue that repo has opened since it, which on a
  # quiet trigger is months. What the fix changes is WHEN: the cursor restarts at the edit
  # rather than at the next tick, so nothing opened in between falls through the gap.
  test "an issue opened between a repos edit and the next tick still fires" do
    edited_at = Time.utc(2026, 7, 13, 10, 0, 0)

    travel_to edited_at do
      @issue_condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end
    assert_equal "2026-07-13T10:00:00Z", @issue_condition.reload.github_last_issue_at

    opened_in_the_gap = item(number: 77, pr: false, created_at: "2026-07-13T10:00:30Z")
    travel_to edited_at + 1.minute do
      stub_search(issue: [ opened_in_the_gap ]) do
        assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
      end
    end

    assert_equal "2026-07-13T10:00:30Z", @issue_condition.reload.github_last_issue_at
  end

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

  test "an issue whose fire fails before spawning does not inherit the previous issue's session" do
    # Where the stale-marker guard is load-bearing. This loop calls #fire over its
    # batch with nothing in between, so `condition.trigger` stays the SAME memoized
    # instance across items — unlike the label path, where #record_fired_key's reload
    # happens to drop the association cache. Without the guard, #51 raising before it
    # reaches #create_session! would read the marker #50 left, count as fired, and drag
    # `last_issue_at` past an issue that never got a session. That is #647's direction:
    # an event silently dropped, permanently, with nothing to say why.
    a = item(number: 50, pr: false, created_at: "2026-07-12T09:00:00Z")
    b = item(number: 51, pr: false, created_at: "2026-07-12T09:00:05Z")

    Trigger.any_instance.stubs(:interpolate_prompt)
      .returns("triage this issue").then.raises(RuntimeError, "the prompt template blew up")

    stub_search(issue: [ a, b ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    Trigger.any_instance.unstub(:interpolate_prompt)

    @issue_condition.reload
    assert_equal [ "tadasant/zimmer#50" ], @issue_condition.github_seen_issue_keys,
                 "#51 never got a session, so it must not be remembered as fired"
    assert_equal "2026-07-12T09:00:00Z", @issue_condition.github_last_issue_at,
                 "the cursor must stop at the last issue that actually produced a session"

    # And it really is retried rather than lost.
    stub_search(issue: [ a, b ]) do
      assert_difference("Session.count", 1) { GithubTriggerPollerJob.perform_now }
    end
    assert_equal [ "tadasant/zimmer#50", "tadasant/zimmer#51" ],
                 @issue_condition.reload.github_seen_issue_keys.sort
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
    assert_equal [], @label_condition.github_seen_items,
                 "state computed against the old scope must be dropped, not written over the edit"
    assert_equal [ "tadasant/zimmer" ], @label_condition.github_baseline_scope["repos"],
                 "the baseline still describes the pre-edit scope the edit stamped — the " \
                 "discarded tick may not advance it to the new one"
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

# ── Liveness heartbeat ──────────────────────────────────────────────────────
#
# The poller's per-condition rescue only alerts when a search RAISES. It cannot catch a
# poller that stops running at all (hung subprocess, downed worker, held concurrency
# slot) — no code runs, so nothing raises, and polling freezes in silence. The heartbeat
# is the signal GithubTriggerHealthCheckJob reads to notice that silence.
#
# Its own class rather than a block in the suite above: the production cache is
# null_store in test, so these need a real store swapped in, and that swap should not
# ride along on the 29 behavioural tests that have no use for it.
class GithubTriggerPollerJobHeartbeatTest < ActiveJob::TestCase
  include GithubTriggerPollerPreflightStubs

  setup do
    @label_condition = trigger_conditions(:github_label_condition)
    stub_preflight(GithubSearchService::PREFLIGHT_AUTHENTICATED)

    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)
  end

  teardown do
    Rails.cache = @original_cache
  end

  def heartbeat
    Rails.cache.read(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)
  end

  # An item shaped like the search-API fields the poller actually reads.
  def item(number:, labels: [], repo: "tadasant/zimmer")
    {
      "number" => number,
      "title" => "Item #{number}",
      "html_url" => "https://github.com/#{repo}/pull/#{number}",
      "repository_url" => "https://api.github.com/repos/#{repo}",
      "user" => { "login" => "someone" },
      "body" => "body of #{number}",
      "labels" => labels.map { |name| { "name" => name } },
      "created_at" => "2026-07-10T12:00:00Z",
      "pull_request" => { "url" => "x" }
    }
  end

  # Label queries start "is:open "; issue queries start "is:issue ". Dispatch on the
  # query rather than call order, which fixture id hashing makes unreliable.
  def stub_search(label: [], issue: [])
    fake = ->(query, **_opts) { query.start_with?("is:issue ") ? issue : label }
    GithubSearchService.stub(:search_issues, fake) { yield }
  end

  test "a successful poll records the heartbeat" do
    stub_search(label: [ item(number: 1, labels: [ "ready to merge" ]) ]) do
      GithubTriggerPollerJob.perform_now
    end

    assert_not_nil heartbeat, "a poll that reached GitHub should stamp the heartbeat"
    assert_in_delta Time.current.to_f, Time.iso8601(heartbeat).to_f, 5
  end

  test "a poll where every condition fails does NOT record the heartbeat" do
    # The crux: the per-condition rescue lets perform RETURN normally even though
    # nothing was actually polled. If "perform returned" counted as liveness, a total
    # GitHub outage would keep the heartbeat fresh and the health check would sit
    # silent through exactly the incident it exists to catch.
    AlertService.stubs(:raise_alert)
    GithubSearchService.stub(:search_issues, ->(*, **) { raise GithubSearchService::SearchError, "502" }) do
      GithubTriggerPollerJob.perform_now
    end

    assert_nil heartbeat, "a sweep in which no condition polled successfully is not liveness"
  end

  test "a poll where only some conditions fail still records the heartbeat" do
    # A single broken condition pages on its own via the per-condition alert; it must
    # not also trip the stall alarm, because the poller itself is demonstrably alive.
    AlertService.stubs(:raise_alert)
    fake = lambda do |query, **_opts|
      raise GithubSearchService::SearchError, "502" if query.start_with?("is:issue ")
      [ item(number: 1, labels: [ "ready to merge" ]) ]
    end

    GithubSearchService.stub(:search_issues, fake) { GithubTriggerPollerJob.perform_now }

    assert_not_nil heartbeat, "one healthy condition is enough to prove the poller is alive"
  end

  test "a tick with no GitHub triggers at all still records the heartbeat" do
    # Otherwise the key rots while there is legitimately nothing to poll, and enabling a
    # trigger flips the health check on against that stale value — paging for a poller
    # that is working perfectly. Ordinary trigger admin must not cry wolf.
    Trigger.with_github_conditions.destroy_all

    GithubTriggerPollerJob.perform_now

    assert_not_nil heartbeat, "a tick that correctly found nothing to do is still liveness"
  end

  test "a tick skipped for a missing gh credential does not record the heartbeat" do
    # An unconfigured host never polls, so it must not look alive. (The health check
    # makes the same credential check, so this gap never pages there.)
    stub_preflight(GithubSearchService::PREFLIGHT_UNCONFIGURED, "no github.com credential is configured")

    GithubTriggerPollerJob.perform_now

    assert_nil heartbeat
  end

  test "a heartbeat write failure does not break an otherwise successful poll" do
    Rails.cache.stubs(:write).raises(StandardError, "Redis connection refused")

    stub_search(label: [ item(number: 1, labels: [ "ready to merge" ]) ]) do
      assert_nothing_raised { GithubTriggerPollerJob.perform_now }
    end

    # The poll's real work still landed.
    assert_equal [ "tadasant/zimmer#1:ready to merge" ], @label_condition.reload.github_seen_items
  end
end

# ── Sustained incomplete searches ───────────────────────────────────────────
#
# A single incomplete search is a self-healing blip and is skipped in silence (above).
# A run of them is not: the condition is not being polled at all, so its trigger is dark
# for as long as it lasts. This is where that becomes visible again.
#
# Its own class for the same reason the heartbeat suite is: the streak lives in
# Rails.cache, which is null_store in test, so these need a real store swapped in.
class GithubTriggerPollerJobIncompleteSearchTest < ActiveJob::TestCase
  include GithubTriggerPollerPreflightStubs

  setup do
    @label_condition = trigger_conditions(:github_label_condition)
    stub_preflight(GithubSearchService::PREFLIGHT_AUTHENTICATED)

    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  # One tick. The label condition's search comes back incomplete (or not); the issue
  # condition's always succeeds with nothing to report, so the poller is demonstrably
  # alive and only the label condition's own streak is under test.
  def poll(incomplete: true)
    fake = lambda do |query, **_opts|
      if incomplete && query.start_with?("is:open ")
        raise GithubSearchService::IncompleteResultsError,
              "GitHub search returned incomplete results for query: #{query}"
      end
      []
    end

    GithubSearchService.stub(:search_issues, fake) { GithubTriggerPollerJob.perform_now }
  end

  # Titles of the alerts raised while the block runs.
  def capture_alerts
    titles = []
    AlertService.stubs(:raise_alert).with do |*args, **_kwargs|
      titles << args.first
      true
    end
    yield
    titles
  end

  test "a run of incomplete searches below the threshold never pages" do
    below = GithubTriggerPollerJob::CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT - 1

    titles = capture_alerts { below.times { poll } }

    assert_empty titles, "#{below} consecutive index blips is still a transient, not a page"
  end

  test "an incomplete search index that will not clear pages once the streak is unbroken" do
    threshold = GithubTriggerPollerJob::CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT

    titles = capture_alerts { threshold.times { poll } }

    assert_includes titles, "GitHub search index degraded",
                    "a degradation lasting #{threshold} consecutive ticks must become visible"
  end

  test "a single clean poll resets the streak, so scattered blips never accumulate into a page" do
    # The distinction that makes the threshold mean "consecutive" rather than "total":
    # blips a week apart must not add up to an alert.
    below = GithubTriggerPollerJob::CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT - 1

    titles = capture_alerts do
      below.times { poll }
      poll(incomplete: false)
      below.times { poll }
    end

    assert_empty titles, "a successful poll in between must clear the run"
  end

  test "a tick in which every condition hits an incomplete index does not record the heartbeat" do
    # The other half of the safety net, and why no extra machinery is needed for a broad
    # GitHub search outage: when nothing polls successfully the heartbeat is never stamped,
    # so GithubTriggerHealthCheckJob pages on the stale value at its own threshold.
    Rails.cache.delete(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)

    everything_incomplete = lambda do |query, **_opts|
      raise GithubSearchService::IncompleteResultsError,
            "GitHub search returned incomplete results for query: #{query}"
    end

    GithubSearchService.stub(:search_issues, everything_incomplete) { GithubTriggerPollerJob.perform_now }

    assert_nil Rails.cache.read(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY),
               "a sweep in which no condition polled successfully is not liveness"
  end

  test "the streak is tracked per condition, so one bad query does not escalate another's" do
    threshold = GithubTriggerPollerJob::CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT
    threshold.times { poll }

    assert_equal threshold,
                 Rails.cache.read(GithubTriggerPollerJob.incomplete_search_streak_key(@label_condition.id))
    assert_nil Rails.cache.read(
      GithubTriggerPollerJob.incomplete_search_streak_key(trigger_conditions(:github_issue_condition).id)
    ), "the condition that polled cleanly must carry no streak at all"
  end

  # ── a transient `gh` failure, end to end ──────────────────────────────────
  #
  # #436, driven through the whole job rather than through GithubSearchService alone,
  # because the defect was never in one method: it was that a single non-zero exit reached
  # perform's per-condition rescue, which pages. These two go through the real service and
  # the real subprocess boundary, stubbing only BoundedSubprocess.

  # Reduce the sweep to the label condition, so the assertions below are about it and the
  # `gh` calls are the ones this test set up.
  def only_label_condition!
    Trigger.where.not(id: @label_condition.trigger_id).update_all(status: "disabled")
  end

  # A search response as `gh api` prints it, carrying one labelled PR.
  def gh_payload(numbers)
    items = numbers.map do |n|
      {
        "number" => n,
        "title" => "Item #{n}",
        "html_url" => "https://github.com/tadasant/zimmer/pull/#{n}",
        "repository_url" => "https://api.github.com/repos/tadasant/zimmer",
        "user" => { "login" => "someone" },
        "body" => "body of #{n}",
        "labels" => [ { "name" => "ready to merge" } ],
        "created_at" => "2026-07-10T12:00:00Z",
        "pull_request" => { "url" => "x" }
      }
    end

    JSON.generate({ "total_count" => items.length, "incomplete_results" => false, "items" => items })
  end

  test "a 401 that clears on retry fires the trigger without paging anyone" do
    # 2026-08-14T08:00:05Z in production: `gh: Bad credentials (HTTP 401)` against a
    # credential that was valid before and after. It paged, and the condition polled
    # cleanly on the very next tick — so the page arrived at a healed system.
    only_label_condition!
    GithubSearchService.stubs(:sleep)
    BoundedSubprocess.expects(:run).twice.returns(
      [ "", "gh: Bad credentials (HTTP 401)", fake_process_status(exitstatus: 1) ],
      [ gh_payload([ 7 ]), "", fake_process_status(exitstatus: 0) ]
    )
    AlertService.expects(:raise_alert).never

    assert_difference "Session.count", 1 do
      GithubTriggerPollerJob.perform_now
    end

    # The tick did real work: the item is in the seen-set and the heartbeat is stamped,
    # so the health check reads this as a living poller rather than a stalled one.
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], @label_condition.reload.github_seen_items
    assert_not_nil Rails.cache.read(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)
  end

  test "a 504 during a search that ends incomplete pages, rather than skipping quietly" do
    # The suppression a retry could have introduced, asserted where it would have bitten:
    # #skip_incomplete_search deliberately does NOT page (the index recovers by itself), so
    # a search that failed outright must not arrive there wearing IncompleteResultsError.
    only_label_condition!
    GithubSearchService.stubs(:sleep)
    incomplete = JSON.generate({ "total_count" => 2, "incomplete_results" => true, "items" => [] })
    failed = [ "", "gh: We couldn't respond to your request in time … (HTTP 504)", fake_process_status(exitstatus: 1) ]
    ok = [ incomplete, "", fake_process_status(exitstatus: 0) ]
    BoundedSubprocess.stubs(:run).returns(failed, ok, failed, ok, ok)

    alerted = []
    AlertService.stubs(:raise_alert).with do |title, **kwargs|
      alerted << [ title, kwargs[:error]&.message ]
      true
    end

    GithubTriggerPollerJob.perform_now

    assert_equal 1, alerted.length, "a hard failure must page, not be absorbed as an index blip"
    assert_equal "GitHub trigger poller error", alerted.first.first
    assert_includes alerted.first.last, "failed outright"
    # Not the incomplete-search escalation, whose alert would have blamed the query.
    assert_nil Rails.cache.read(
      GithubTriggerPollerJob.incomplete_search_streak_key(@label_condition.id)
    ), "this is not an incomplete-index tick and must not be counted into that streak"
  end

  test "a 401 that never clears still pages, on this tick and every tick after" do
    # The half of the fix that must not regress. A revoked credential that somehow reaches
    # the search (rather than being caught by the auth preflight) is a real
    # failure, and retrying must delay the page by seconds — not remove it.
    only_label_condition!
    GithubSearchService.stubs(:sleep)
    BoundedSubprocess.stubs(:run).returns([ "", "gh: Bad credentials (HTTP 401)", fake_process_status(exitstatus: 1) ])

    alerted = []
    AlertService.stubs(:raise_alert).with do |title, **kwargs|
      alerted << [ title, kwargs[:error]&.message ]
      true
    end

    assert_no_difference "Session.count" do
      GithubTriggerPollerJob.perform_now
    end

    assert_equal 1, alerted.length
    assert_equal "GitHub trigger poller error", alerted.first.first
    assert_includes alerted.first.last, "Bad credentials"
    assert_includes alerted.first.last, "still failing after 3 attempts"
    # No condition polled cleanly, so this sweep is not liveness either — the stale
    # heartbeat is what escalates a total outage, per GithubTriggerHealthCheckJob.
    assert_nil Rails.cache.read(GithubTriggerPollerJob::HEARTBEAT_CACHE_KEY)
  end
end
