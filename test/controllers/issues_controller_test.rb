# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"
require "support/issues_helpers"

# The page. GitHub is stubbed at Issues::GithubSnapshot.fetch — the page must
# render from a snapshot, whatever GitHub is doing.
class IssuesControllerTest < ActionDispatch::IntegrationTest
  include WorkBacklogHelpers
  include IssuesHelpers

  test "renders the queue, the in-flight list and the GitHub half" do
    backlog_item(key: "zimmer#498", title: "Queued and waiting", issue_url: url(498))
    running = backlog_item(key: "zimmer#499", title: "Already running", issue_url: url(499))
    running.mark_started!(session: sessions(:running), by: nil)

    with_github_snapshot(github_snapshot(issues: [ github_issue(number: 498), github_issue(number: 700, title: "Not on the queue") ])) do
      get issues_path
    end

    assert_response :success
    assert_select "h1", "Issues"
    assert_match "Queued and waiting", response.body
    assert_match "Already running", response.body
    assert_match "Not on the queue", response.body
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
