# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubTriggerPollerJobTest < ActiveJob::TestCase
  setup do
    @label_condition = trigger_conditions(:github_label_condition)
    @issue_condition = trigger_conditions(:github_issue_condition)
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

  test "new-issue query scopes to issues in the watched repos since the cursor" do
    stub_search do |queries|
      GithubTriggerPollerJob.perform_now
      query = queries.find { |q| q.start_with?("is:issue ") }
      assert_equal "is:issue (repo:tadasant/zimmer) created:>=2026-07-01T00:00:00Z", query
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
end
