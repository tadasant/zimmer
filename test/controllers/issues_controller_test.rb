# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"
require "support/issues_helpers"

# The page. GitHub is stubbed at Issues::GithubSnapshot.fetch — the page must
# render from a snapshot, whatever GitHub is doing.
class IssuesControllerTest < ActionDispatch::IntegrationTest
  include WorkBacklogHelpers
  include IssuesHelpers

  test "renders the queue, the three started lists and the GitHub half" do
    backlog_item(key: "zimmer#498", title: "Queued and waiting", issue_url: url(498))
    running = backlog_item(key: "zimmer#499", title: "Already running", issue_url: url(499))
    running.mark_started!(session: sessions(:running), by: nil)
    parked = backlog_item(key: "zimmer#500", title: "Parked on its PR", issue_url: url(500))
    parked.mark_started!(session: sessions(:needs_input), by: nil, now: 20.hours.ago)
    finished = backlog_item(key: "zimmer#501", title: "Ran and archived", issue_url: url(501))
    finished.mark_started!(session: sessions(:archived), by: nil, now: 6.hours.ago)
    sessions(:archived).update!(archived_at: 1.hour.ago)

    with_github_snapshot(github_snapshot(issues: [ github_issue(number: 498), github_issue(number: 700, title: "Not on the queue") ])) do
      get issues_path
    end

    assert_response :success
    assert_select "h1", "Issues"
    assert_match "Queued and waiting", response.body
    assert_match "Already running", response.body
    assert_select "h2", text: /Parked on a person/
    assert_match "Parked on its PR", response.body
    assert_select "h2", text: /Finished recently/
    assert_match "Ran and archived", response.body
    assert_match "Not on the queue", response.body
  end

  # The population the page used to hide: an item the fleet started and dropped
  # rendered only in the GitHub list, as an ordinary un-triaged issue. It gets a
  # section and a count of its own, and each row says what the sweep concluded.
  test "a started item whose session ended long ago is listed as stranded, with the sweep's verdict" do
    dropped = backlog_item(key: "zimmer#600", title: "Dropped by its session", issue_url: url(600))
    dropped.mark_started!(session: sessions(:archived), by: nil, now: 4.days.ago)
    dropped.record_liveness!(WorkBacklogItem::LIVENESS_PR_STALLED)
    sessions(:archived).update!(archived_at: 3.days.ago)

    with_github_snapshot(github_snapshot(issues: [ github_issue(number: 600) ])) { get issues_path }

    assert_response :success
    assert_select "h2", text: /Stranded/
    assert_match "Dropped by its session", response.body
    assert_match "pr stalled", response.body
    assert_select "div", text: "Stranded" do |labels|
      assert_equal "1", labels.first.parent.at_css("div.tabular-nums").text.strip
    end
  end

  # The number Tadas read off this page, and the number the WIP ceiling is
  # computed against, have to be the same number. A session parked in
  # `needs_input` for a day is counted in neither.
  test "the count strip separates what an agent is advancing from what is waiting on a person" do
    running = backlog_item(key: "zimmer#1")
    running.mark_started!(session: sessions(:running), by: nil)
    2.times do |i|
      parked = backlog_item(key: "zimmer##{20 + i}")
      parked.mark_started!(session: sessions(:needs_input), by: nil)
    end

    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    assert_select "div", text: "In flight" do |labels|
      assert_equal "1", labels.first.parent.at_css("div.tabular-nums").text.strip
    end
    assert_select "div", text: "Parked on a person" do |labels|
      assert_equal "2", labels.first.parent.at_css("div.tabular-nums").text.strip
    end
  end

  # The sentence that made a stalled queue read as healthy. "N an agent is still
  # advancing" is false of a session the spot gate has never started, and with
  # enough of them the fleet is idle behind a quota window while the page and the
  # groomer both report a full ceiling (#1103). The header splits so the two are
  # distinguishable on sight.
  test "the In flight header names the ones held at the spot gate rather than calling them advanced" do
    working = backlog_item(key: "zimmer#1")
    working.mark_started!(session: sessions(:running), by: nil)
    held = backlog_item(key: "zimmer#2")
    at_the_gate = sessions(:waiting)
    at_the_gate.update!(metadata: (at_the_gate.metadata || {}).merge(
      SpotSessionHold::HELD_REASON => SpotGateService::UTILIZATION_REASON,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    ))
    held.mark_started!(session: at_the_gate, by: nil)

    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    assert_match(/1 an agent is still advancing, 1 held at the spot gate before a turn/, response.body)
    # Both are still in flight and both are still listed — only the reading changed.
    assert_select "div", text: "In flight" do |labels|
      assert_equal "2", labels.first.parent.at_css("div.tabular-nums").text.strip
    end
  end

  test "the In flight header says only what it used to when nothing is held" do
    backlog_item(key: "zimmer#1").mark_started!(session: sessions(:running), by: nil)

    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    assert_match(/1 an agent is still advancing/, response.body)
    assert_no_match(/held at the spot gate/, response.body)
  end

  test "the filters narrow the queue and are round-tripped into the promote button" do
    backlog_item(key: "zimmer#1", title: "A bug", kind: "bug")
    backlog_item(key: "zimmer#2", title: "Some tech debt", kind: "tech-debt")

    with_github_snapshot(github_snapshot) { get issues_path(kind: "bug", window: 90, segment: "repo") }

    assert_response :success
    assert_match "A bug", response.body
    assert_no_match(/Some tech debt/, response.body)
    assert_select "form[action=?]", promote_work_backlog_item_path(WorkBacklogItem.find_by(key: "zimmer#1"), kind: "bug", window: 90, segment: "repo")
  end

  test "every queued row carries all four human-only operations, each wired to its own row" do
    first = backlog_item(key: "zimmer#498", title: "First", precedence: 6000)
    second = backlog_item(key: "zimmer#499", title: "Second", precedence: 5990)

    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    [ first, second ].each do |item|
      assert_select "form[action=?][method=post]", promote_work_backlog_item_path(item)
      assert_select "form[action=?][method=post]", pin_work_backlog_item_path(item)
      assert_select "form[action=?][method=post]", remove_work_backlog_item_path(item)
    end

    # THE WRONG-ROW ASSERTION, on the page rather than in the controller: each
    # row's remove form posts to that row's id and its confirmation names that
    # row's key, so a partial rendered with the wrong `row` is caught here.
    assert_select "form[action=?]", remove_work_backlog_item_path(second) do
      assert_select "[data-turbo-confirm*=?]", "zimmer#499"
      assert_select "input[name=reason]"
    end
    assert_select "form[action=?]", remove_work_backlog_item_path(first) do
      assert_select "[data-turbo-confirm*=?]", "zimmer#498"
    end

    # The pin field is seeded with the row's own current precedence.
    assert_select "form[action=?]", pin_work_backlog_item_path(first) do
      assert_select "input[name=precedence][value=?]", "6000"
    end
    assert_select "form[action=?]", pin_work_backlog_item_path(second) do
      assert_select "input[name=precedence][value=?]", "5990"
    end
  end

  test "a pinned row offers unpin instead of a precedence field" do
    pinned = backlog_item(key: "zimmer#498", pinned: true, precedence: 9000)

    with_github_snapshot(github_snapshot) { get issues_path }

    # Pin and unpin share a path and differ by verb, so the assertion that a
    # pinned row offers only the release is about the method and the field, not
    # the action.
    assert_select "form[action=?]", unpin_work_backlog_item_path(pinned) do
      assert_select "input[name=_method][value=delete]"
      assert_select "button", text: "Unpin"
    end
    assert_select "input[name=precedence]", count: 0,
                  message: "a pinned row does not also offer a precedence field"
  end

  test "a queued item whose issue GitHub says is closed pre-fills the removal reason" do
    open_item = backlog_item(key: "zimmer#498", issue_url: url(498))
    closed_item = backlog_item(key: "zimmer#499", issue_url: url(499))

    snapshot = github_snapshot(issues: [ github_issue(number: 498), github_issue(number: 499, state: "closed") ])
    with_github_snapshot(snapshot) { get issues_path }

    assert_select "form[action=?]", remove_work_backlog_item_path(closed_item) do
      assert_select "input[name=reason][value=?]", WorkBacklogItem::ISSUE_CLOSED_REASON
    end
    assert_select "form[action=?]", remove_work_backlog_item_path(open_item) do
      assert_select "input[name=reason][value]", count: 0, message: "an open issue's reason field starts blank"
    end
  end

  test "the filters are round-tripped into the pin and remove controls too" do
    item = backlog_item(key: "zimmer#1", title: "A bug", kind: "bug")
    view = { kind: "bug", window: 90, segment: "repo" }

    with_github_snapshot(github_snapshot) { get issues_path(**view) }

    assert_select "form[action=?]", pin_work_backlog_item_path(item, **view)
    assert_select "form[action=?]", remove_work_backlog_item_path(item, **view)
  end

  test "a filter the queue cannot honour is said out loud rather than silently widened" do
    backlog_item(key: "zimmer#1", title: "Still here")

    with_github_snapshot(github_snapshot) { get issues_path(estimated_cost: "enormous") }

    assert_response :success
    assert_match "Still here", response.body
    assert_match(/Showing the queue unfiltered/, flash[:alert].to_s)
  end

  test "the window and segment controls are honoured, and anything else falls back" do
    with_github_snapshot(github_snapshot) { get issues_path(window: 180, segment: "label") }
    assert_response :success
    assert_select "a[aria-current='true']", text: "180d"
    assert_select "a[aria-current='true']", text: "label"

    with_github_snapshot(github_snapshot) { get issues_path(window: 4242, segment: "sideways") }
    assert_response :success
    assert_select "a[aria-current='true']", text: "#{Issues::GithubSnapshot::WINDOWS.first}d"
    assert_select "a[aria-current='true']", text: Issues::Trend::DEFAULT_SEGMENT
  end

  test "a promote's session is linked once it exists, and a stale id renders no banner" do
    session = sessions(:running)

    with_github_snapshot(github_snapshot) { get issues_path(promoted_session_id: session.id) }
    assert_response :success
    assert_select "a[href=?]", session_path(session), text: "session ##{session.id}"

    with_github_snapshot(github_snapshot) { get issues_path(promoted_session_id: 999_999) }
    assert_response :success
    assert_no_match(/Started\s+<a/, response.body)
  end

  test "an issue_url that is not an http(s) URL is rendered as text, never as an href" do
    # `issue_url` is agent-written and only length-validated, so a session holding
    # the fleet's shared API key can put a scheme in it. Nothing may link it.
    hostile = "javascript:fetch('/api/v1/work_backlog_items')"
    backlog_item(key: "zimmer#1", title: "Queued with a hostile url", issue_url: hostile)
    started = backlog_item(key: "zimmer#2", title: "Started with a hostile url", issue_url: hostile)
    started.mark_started!(session: sessions(:running), by: nil)

    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    assert_match "Queued with a hostile url", response.body
    assert_match "Started with a hostile url", response.body
    assert_no_match(/href="javascript:/, response.body)
    assert_select "a[href^=?]", "javascript:", count: 0
  end

  test "a gate session recorded as prose rather than a URL is not linked" do
    backlog_item(key: "zimmer#1", title: "Cleared by hand",
                 payload: { "gate_session" => "the groomer ran it by hand" })

    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    assert_no_match(/gate session/, response.body)
  end

  test "a nested promoted_session_id is ignored rather than 500ing the page" do
    with_github_snapshot(github_snapshot) { get issues_path(promoted_session_id: { "a" => "1" }) }

    assert_response :success
  end

  test "a hostile URL is rendered as text on both halves of the page, whoever wrote it" do
    # The queue's `issue_url` is agent-written and only length-validated; the
    # loose list's URL comes from GitHub. Neither is a reason to put an
    # unvalidated scheme in an href.
    backlog_item(key: "zimmer#1", title: "Queued with a bad URL", issue_url: "javascript:alert('queue')")
    snapshot = github_snapshot(issues: [
      Issues::GithubIssue.new(repo: "tadasant/zimmer", number: 9, title: "Loose with a bad URL",
                              url: "javascript:alert('github')", state: "open",
                              created_at: 3.days.ago, closed_at: nil, labels: [])
    ])

    with_github_snapshot(snapshot) { get issues_path }

    assert_response :success
    assert_match "Queued with a bad URL", response.body
    assert_match "Loose with a bad URL", response.body
    assert_no_match(/href="javascript:/, response.body)
    assert_select "a[href^=?]", "javascript:", false
  end

  # The owner is not uniform across GithubSnapshot::REPOS — `pulsemcp/air` sits
  # beside the tadasant ones — and the filter prints the short name alone, so the
  # option's title is the only place the owner is legible without leaving the page.
  test "every watched repo is a repo filter option carrying its full owner/repo as a title" do
    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    Issues::GithubSnapshot::REPOS.each do |repo|
      assert_select %(select#repo option[value='#{repo}'][title='#{repo}']), 1,
                    "#{repo} must be selectable, and must say who owns it"
    end
    assert_select %(select#repo option[value='pulsemcp/air']), text: "air"
  end

  test "a repo GitHub could not be read is named on the page" do
    snapshot = github_snapshot(errors: { "tadasant/motet" => "gh api search/issues failed" })

    with_github_snapshot(snapshot) { get issues_path }

    assert_response :success
    assert_match "gh api search/issues failed", response.body
  end

  test "renders with no backlog and no GitHub issues at all" do
    with_github_snapshot(github_snapshot) { get issues_path }

    assert_response :success
    assert_match(/Nothing is on the work backlog yet/, response.body)
  end

  test "refresh drops the cached read and comes back to the page it was pressed on" do
    forced = []
    Issues::GithubSnapshot.stub(:fetch, ->(force: false) { forced << force; github_snapshot }) do
      post refresh_issues_path(repo: "tadasant/zimmer", window: 90)
    end

    assert_equal [ true ], forced
    assert_redirected_to issues_path(repo: "tadasant/zimmer", window: 90)
  end

  test "a refresh that cannot reach GitHub reports it instead of 500ing" do
    Issues::GithubSnapshot.stub(:fetch, ->(**) { raise GithubSearchService::SearchError, "GitHub is down" }) do
      post refresh_issues_path
    end

    assert_redirected_to issues_path
    assert_match(/GitHub is down/, flash[:alert])
  end

  private

  def url(number) = "https://github.com/tadasant/zimmer/issues/#{number}"
end
