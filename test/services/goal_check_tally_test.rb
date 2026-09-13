require "test_helper"
require "mocha/minitest"

# GoalCheckTally is the measurement tadasant/zimmer#88 asked for before any
# consequence is attached to a verdict. What these pin is that it counts the right
# sessions (at rest, in the window, with a checked goal) and breaks a false reading
# down the way it would show up: by the criteria that kept a session from met, by
# root, and by whether the session holds a PR of its own.
class GoalCheckTallyTest < ActiveSupport::TestCase
  PR = "https://github.com/owner/repo/pull/7".freeze

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.delete_all
  end

  def make_session(goal: "open-reviewed-green-pr", status: :archived, custom_metadata: {}, created_at: 1.day.ago,
                   root: "zimmer", parent: nil, title: "Work")
    Session.create!(
      title: title, agent_runtime: "claude_code", status: status, prompt: "p", goal: goal,
      git_root: "https://github.com/owner/repo.git", branch: "main",
      archived_at: (status == :archived ? created_at + 1.hour : nil), created_at: created_at,
      metadata: { "agent_root_key" => root }, custom_metadata: custom_metadata, parent_session_id: parent&.id
    )
  end

  def pr_metadata(url = PR, status: "open", ci: "pass", section: true, checked: 2, unchecked: 0, labels: [ "ready to merge" ])
    {
      "github_pull_request_urls" => [ url ],
      "github_pull_request_statuses" => { url => status },
      "github_pull_request_ci_statuses" => { url => ci },
      "github_pull_request_goal_facts" => {
        url => { "verification_section" => section, "verification_checked_boxes" => checked,
                 "unchecked_boxes" => unchecked, "labels" => labels }
      }
    }
  end

  def tally(**filters)
    GoalCheckTally.new(filters: OutcomeAnalyses::LedgerFilters.new(**filters))
  end

  test "counts sessions at rest with a checked goal, and leaves running, waiting and free-text sessions out of the verdicts" do
    make_session(custom_metadata: pr_metadata)
    make_session(status: :needs_input, custom_metadata: pr_metadata(labels: []))
    make_session(status: :running, custom_metadata: pr_metadata(labels: []))
    make_session(status: :waiting, custom_metadata: pr_metadata(labels: []))
    make_session(goal: "Fix the flaky login test and open a PR")

    result = tally

    assert_equal 3, result.resting_sessions, "archived + needs_input, checked or not"
    assert_equal 2, result.checked_sessions
    assert_equal({ "met" => 1, "unmet" => 1, "pending" => 0 }, result.verdicts)
  end

  test "with no dates it covers the last week of created sessions" do
    make_session(custom_metadata: pr_metadata)
    make_session(custom_metadata: pr_metadata, created_at: 10.days.ago)

    assert_equal 1, tally.checked_sessions
    assert_equal 2, tally(from: 30.days.ago.to_date.iso8601).checked_sessions
  end

  test "a `to` with no `from` is bounded to the window before it, not all history" do
    make_session(custom_metadata: pr_metadata, created_at: 10.days.ago)
    make_session(custom_metadata: pr_metadata, created_at: 40.days.ago)

    result = tally(to: 5.days.ago.to_date.iso8601)

    assert_equal 1, result.checked_sessions
    assert_equal (5.days.ago - GoalCheckTally::DEFAULT_WINDOW).beginning_of_day.to_date, result.from_time.to_date
  end

  test "groups unmet and pending sessions by the criteria that kept them from met, with sample ids" do
    no_pr = make_session
    no_label = make_session(custom_metadata: pr_metadata(labels: []))
    ci_running = make_session(custom_metadata: pr_metadata(ci: "pending"))

    result = tally
    unmet = result.unmet_reasons.to_h { |reason| [ reason.criteria, reason ] }

    assert_equal [ no_pr.id ], unmet.fetch([ "pull_request_open" ]).sample_session_ids
    assert_equal [ no_label.id ], unmet.fetch([ "ready_to_merge_label" ]).sample_session_ids
    assert_equal [ [ "ci_green" ] ], result.pending_reasons.map(&:criteria)
    assert_equal [ ci_running.id ], result.pending_reasons.first.sample_session_ids
    # The session with no PR has no CI to read: unknown, not unmet.
    assert_equal({ "met" => 1, "unmet" => 0, "pending" => 1, "unknown" => 1 }, result.criteria.fetch("ci_green"))
  end

  test "a router is judged on the PR its child recorded, and counted as delegated" do
    router = make_session(root: "zimmer-orchestrator", title: "Route it")
    make_session(parent: router, status: :archived, custom_metadata: pr_metadata(status: "merged"))

    result = tally(agent_root: "zimmer-orchestrator")

    assert_equal 1, result.checked_sessions
    assert_equal({ "met" => 1, "unmet" => 0, "pending" => 0 }, result.verdicts)
    assert_equal 1, result.delegated_sessions
  end

  test "unmet on its own pull request lists only sessions whose own PR is what fails, not a missing record" do
    own = make_session(status: :needs_input, custom_metadata: pr_metadata(labels: [], unchecked: 1), title: "Holding a PR")
    make_session(title: "No PR at all")
    router = make_session(root: "zimmer-orchestrator", title: "Router")
    make_session(parent: router, status: :needs_input, custom_metadata: pr_metadata(labels: []), title: "Child")

    result = tally

    listed = result.unmet_on_own_pull_request.map(&:session_id)
    assert_includes listed, own.id
    assert_not_includes listed, router.id, "a router's delegated PR is its child's to fix"
    assert_equal 2, result.unmet_on_own_pull_request_count, "the holder and the child"
    row = result.unmet_on_own_pull_request.find { |r| r.session_id == own.id }
    assert_equal %w[verification_boxes_checked ready_to_merge_label], row.unmet_criteria
  end

  test "rows by agent root and by goal carry the verdict split" do
    make_session(root: "zimmer", custom_metadata: pr_metadata)
    make_session(root: "zimmer", custom_metadata: pr_metadata(ci: "fail"))
    make_session(root: "strad", goal: "codebase-question")

    roots = tally.by_agent_root.to_h { |row| [ row.key, row ] }
    assert_equal [ 2, 1, 1, 0 ], roots.fetch("zimmer").to_h.values_at(:sessions, :met, :unmet, :pending)
    assert_equal [ 1, 1, 0, 0 ], roots.fetch("strad").to_h.values_at(:sessions, :met, :unmet, :pending)
    assert_equal %w[open-reviewed-green-pr codebase-question], tally.by_goal.map(&:key)
  end

  test "to_h is the JSON the REST endpoint and the MCP view render" do
    make_session(status: :needs_input, custom_metadata: pr_metadata(labels: []))

    json = tally.to_h

    assert_equal %i[window resting_sessions checked_sessions verdicts delegated_sessions criteria unmet_reasons
                    pending_reasons by_goal by_agent_root unmet_on_own_pull_request], json.keys
    assert_equal 1, json[:unmet_on_own_pull_request][:sessions]
    assert_equal [ "ready_to_merge_label" ], json[:unmet_reasons].first[:criteria]
  end
end
