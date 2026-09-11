# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The liveness re-check over `started` rows: which of the five outcomes each row
# gets, and what a re-queue does to the queue.
class WorkBacklog::StaleStartSweepTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  ISSUE_URL = "https://github.com/tadasant/zimmer/issues/1"

  setup do
    @dead_session = sessions(:archived)
    @dead_session.update_columns(archived_at: 3.days.ago, custom_metadata: {})
  end

  # --- the three-way decision ------------------------------------------------

  test "re-queues a started item whose session ended leaving nothing behind" do
    item = stranded_item

    result = sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })

    assert_equal [ item.key ], result.requeued_keys
    assert_equal 1, result.count(WorkBacklogItem::LIVENESS_REQUEUED)

    item.reload
    assert item.queued?
    assert_equal 1, item.requeue_count
    assert_nil item.started_session_id
    assert_nil item.started_at
  end

  test "a re-queued item keeps the rank it left with" do
    # Another small item sits at the band's base, so a recomputed precedence
    # would land GAP below it — the bottom of the band, where nothing is reached.
    backlog_item(key: "zimmer#9", cost: "small", precedence: 6000)
    item = stranded_item(precedence: 6990)

    sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })

    assert_equal 6990, item.reload.precedence
    assert_equal [ item.key, "zimmer#9" ], queued_keys
  end

  test "marks an item whose issue has closed, and never looks at it again" do
    item = stranded_item

    result = sweep(open_issues: [], closed_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })

    assert_empty result.requeued_keys
    assert_equal WorkBacklogItem::LIVENESS_ISSUE_CLOSED, item.reload.liveness_state
    assert item.started?
    assert_empty WorkBacklog::StaleStartSweep.candidates(Time.current)
  end

  test "leaves an item alone when GitHub links a PR to its still-open issue" do
    item = stranded_item

    sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [ ISSUE_URL ] })

    assert_equal WorkBacklogItem::LIVENESS_ISSUE_HAS_OPEN_PR, item.reload.liveness_state
    assert item.started?
    assert_equal 0, item.requeue_count
  end

  test "leaves an item alone when its own session merged a PR the issue never closed" do
    item = stranded_item
    @dead_session.update_columns(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/tadasant/zimmer/pull/5" ],
      "github_pull_request_statuses" => { "https://github.com/tadasant/zimmer/pull/5" => "merged" }
    })

    sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })

    assert_equal WorkBacklogItem::LIVENESS_PR_MERGED, item.reload.liveness_state
    assert item.started?
  end

  # The case GitHub cannot answer: a PR with no closing keyword in it, so
  # `linked:pr` says nothing and the work is nevertheless done.
  test "leaves an item alone when its session left an unresolved PR" do
    item = stranded_item
    @dead_session.update_columns(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/tadasant/zimmer/pull/6" ]
    })

    sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })

    assert_equal WorkBacklogItem::LIVENESS_SESSION_PR_OPEN, item.reload.liveness_state
    assert item.started?
  end

  test "re-queues an item whose session's only PR was closed unmerged" do
    item = stranded_item
    @dead_session.update_columns(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/tadasant/zimmer/pull/7" ],
      "github_pull_request_statuses" => { "https://github.com/tadasant/zimmer/pull/7" => "closed" }
    })

    sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })

    assert item.reload.queued?
  end

  # --- what must not be touched ---------------------------------------------

  test "never examines a row whose session is still alive" do
    item = stranded_item
    item.update_columns(started_session_id: sessions(:running).id)

    assert_empty WorkBacklog::StaleStartSweep.candidates(Time.current)
    assert_equal 0, sweep(open_issues: [ ISSUE_URL ]).examined
    assert item.reload.started?
  end

  test "never examines a row whose session ended inside the grace" do
    item = stranded_item
    @dead_session.update_columns(archived_at: 5.minutes.ago)

    assert_equal 0, sweep(open_issues: [ ISSUE_URL ]).examined
    assert item.reload.started?
  end

  test "leaves a queued row alone even when its session is long gone" do
    item = backlog_item(key: "zimmer#1", issue_url: ISSUE_URL)

    assert_equal 0, sweep(open_issues: [ ISSUE_URL ]).examined
    assert_nil item.reload.liveness_state
  end

  # --- reads that fail are not conclusions ----------------------------------

  test "an issue the GitHub read did not carry is unknown, not stranded work" do
    item = stranded_item

    result = sweep(open_issues: [], linked: { "tadasant/zimmer" => [] })

    assert_empty result.requeued_keys
    assert_equal WorkBacklogItem::LIVENESS_UNKNOWN, item.reload.liveness_state
    assert item.started?
  end

  test "a repo whose linked-PR search failed leaves its rows alone" do
    item = stranded_item

    result = sweep(open_issues: [ ISSUE_URL ], linked: {})

    assert_empty result.requeued_keys
    assert_equal WorkBacklogItem::LIVENESS_UNKNOWN, item.reload.liveness_state
  end

  # --- the bounds ------------------------------------------------------------

  test "stops re-queuing an item past MAX_REQUEUES and alerts instead" do
    item = stranded_item(requeue_count: WorkBacklog::StaleStartSweep::MAX_REQUEUES)
    alerted = []
    AlertService.stub(:raise_alert, ->(title, **kwargs) { alerted << [ title, kwargs ] }) do
      sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })
    end

    assert item.reload.started?
    assert_equal WorkBacklogItem::LIVENESS_REQUEUE_EXHAUSTED, item.liveness_state
    assert_equal 1, alerted.size
    assert_equal "Work backlog item cannot be recovered", alerted.first.first
  end

  test "does not re-queue an item the gate has already re-appended" do
    item = stranded_item
    backlog_item(key: item.key, issue_url: ISSUE_URL)

    sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] })

    assert item.reload.started?
    assert_equal WorkBacklogItem::LIVENESS_ALREADY_QUEUED, item.liveness_state
  end

  test "re-queues at most MAX_REQUEUES_PER_SWEEP in one pass, leaving the rest for the next" do
    items = (1..(WorkBacklog::StaleStartSweep::MAX_REQUEUES_PER_SWEEP + 2)).map do |n|
      stranded_item(key: "zimmer##{n}", issue_url: "https://github.com/tadasant/zimmer/issues/#{n}",
                    precedence: 6000 - (n * 10))
    end
    urls = items.map(&:issue_url)

    result = sweep(open_issues: urls, linked: { "tadasant/zimmer" => [] })

    assert_equal WorkBacklog::StaleStartSweep::MAX_REQUEUES_PER_SWEEP, result.requeued_keys.size
    assert_equal 2, result.count(WorkBacklog::StaleStartSweep::DEFERRED)
    # The deferred rows kept their (absent) check time, so the next pass sees
    # them first rather than re-reading the head of the list.
    deferred = items.select { |item| item.reload.started? }
    assert deferred.all? { |item| item.liveness_checked_at.nil? }
  end

  test "examines the least-recently-checked rows first" do
    recent = stranded_item(key: "zimmer#1", issue_url: "https://github.com/tadasant/zimmer/issues/1",
                           liveness_checked_at: 1.hour.ago, liveness_state: WorkBacklogItem::LIVENESS_UNKNOWN)
    stale = stranded_item(key: "zimmer#2", issue_url: "https://github.com/tadasant/zimmer/issues/2",
                          liveness_checked_at: 10.days.ago, liveness_state: WorkBacklogItem::LIVENESS_UNKNOWN)
    never = stranded_item(key: "zimmer#3", issue_url: "https://github.com/tadasant/zimmer/issues/3")

    assert_equal [ never.id, stale.id, recent.id ],
                 WorkBacklog::StaleStartSweep.candidates(Time.current).map(&:id)
  end

  # --- what it says ----------------------------------------------------------

  test "reports the age of the oldest stranded row even on a pass that acts on nothing" do
    stranded_item(started_at: 9.days.ago, liveness_state: WorkBacklogItem::LIVENESS_ISSUE_HAS_OPEN_PR,
                  liveness_checked_at: Time.current)

    result = sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [ ISSUE_URL ] })

    assert_in_delta 9.days.to_i, result.oldest_stranded_age, 60
  end

  # Production exports WARN and above only (#584), so a pass that repaired
  # something has to log there to be findable; a quiet pass stays at INFO.
  test "logs a pass that re-queued something at WARN, and a quiet pass at INFO" do
    stranded_item
    log = StringIO.new
    logger = Logger.new(log)

    sweep(open_issues: [ ISSUE_URL ], linked: { "tadasant/zimmer" => [] }, logger: logger)
    assert_match(/WARN .*re-queued 1 \(zimmer#1\)/, log.string)

    log.truncate(0)
    log.rewind
    sweep(open_issues: [ ISSUE_URL ], logger: logger)
    assert_match(/INFO .*examined 0, re-queued 0/, log.string)
    assert_no_match(/WARN/, log.string)
  end

  private

  # A started item whose session ended three days ago — the shape this sweep
  # exists for.
  def stranded_item(**overrides)
    backlog_item(**{
      key: "zimmer#1",
      issue_url: ISSUE_URL,
      status: WorkBacklogItem::STARTED,
      started_session_id: @dead_session.id,
      started_at: 4.days.ago
    }.merge(overrides))
  end

  # One pass with GitHub stubbed: `open_issues` / `closed_issues` are the URLs
  # the snapshot carries, `linked` is `{ repo => urls }` with a missing repo
  # standing for a search that failed.
  def sweep(open_issues: [], closed_issues: [], linked: nil, logger: Rails.logger)
    snapshot = Issues::GithubSnapshot::Snapshot.new(
      issues: open_issues.map { |url| github_issue(url, "open") } +
              closed_issues.map { |url| github_issue(url, "closed") },
      fetched_at: Time.current,
      errors: {}
    )
    linked ||= { "tadasant/zimmer" => [] }

    search = lambda do |query, **|
      repo = query[%r{repo:(\S+)}, 1]
      raise GithubSearchService::SearchError, "boom" unless linked.key?(repo)

      linked.fetch(repo).map { |url| { "html_url" => url } }
    end

    Issues::GithubSnapshot.stub(:fetch, snapshot) do
      GithubSearchService.stub(:search_issues, search) do
        WorkBacklog::StaleStartSweep.sweep!(logger: logger)
      end
    end
  end

  def github_issue(url, state)
    Issues::GithubIssue.new(
      repo: "tadasant/zimmer", number: url[%r{/(\d+)\z}, 1].to_i, title: "An issue", url: url,
      state: state, created_at: 30.days.ago, closed_at: (state == "closed" ? 1.day.ago : nil), labels: []
    )
  end
end
