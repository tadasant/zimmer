require "test_helper"
require "mocha/minitest"

# GoalCheck reads a session's recorded state back against what its goal asks for.
# It is advisory — nothing here acts on the result — so what these pin is that the
# reading is right: a goal that was met reads met, one that was not reads unmet and
# says why, and a goal Zimmer cannot judge is not dressed up as either.
class GoalCheckTest < ActiveSupport::TestCase
  PR = "https://github.com/owner/repo/pull/7".freeze
  OTHER_PR = "https://github.com/owner/other/pull/9".freeze

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(goal:, status: :needs_input, custom_metadata: {})
    Session.create!(
      agent_runtime: "claude_code",
      status: status,
      prompt: "p",
      goal: goal,
      git_root: "https://github.com/owner/repo.git",
      branch: "main",
      custom_metadata: custom_metadata
    )
  end

  # Everything the open-reviewed-green-pr goal asks for that GitHub can show.
  def finished_pr_metadata(url = PR, **overrides)
    {
      "github_pull_request_urls" => [ url ],
      "github_pull_request_statuses" => { url => "open" },
      "github_pull_request_ci_statuses" => { url => "pass" },
      "github_pull_request_goal_facts" => {
        url => {
          "verification_section" => true,
          "verification_checked_boxes" => 3,
          "unchecked_boxes" => 0,
          "labels" => [ "ready to merge" ]
        }
      },
      "poller_last_polled_at" => { "github_pr_poller" => "2026-09-11T12:00:00Z" }
    }.merge(overrides.stringify_keys)
  end

  def statuses(check)
    check.criteria.to_h { |c| [ c.key, c.status ] }
  end

  # ---- which goals are checked ----

  test "a free-text goal has no check" do
    assert_nil GoalCheck.for(make_session(goal: "Fix the flaky login test and open a PR"))
  end

  test "a session with no goal has no check" do
    assert_nil GoalCheck.for(make_session(goal: nil))
  end

  test "a goal stored as its description is checked as that goal" do
    # MCP start_session stores the description, not the id.
    description = GoalsConfig.find("open-reviewed-green-pr").description
    check = GoalCheck.for(make_session(goal: description, custom_metadata: finished_pr_metadata))

    assert_equal "open-reviewed-green-pr", check.goal_id
    assert_equal "met", check.verdict
  end

  test "each checked criterion is the catalog goal's own list, in order" do
    check = GoalCheck.for(make_session(goal: "e2e-verified-green-pr", custom_metadata: finished_pr_metadata))

    assert_equal GoalsConfig.find("e2e-verified-green-pr").checks, check.criteria.map(&:key)
  end

  # ---- a PR goal that was met ----

  test "an open PR with green CI, a checked Verification section and the label is met" do
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata))

    assert_equal "met", check.verdict
    assert_equal 5, check.met_count
    assert_equal Time.utc(2026, 9, 11, 12), check.observed_at
    assert_not check.provisional
  end

  test "a merged PR meets CI and the label without readings for either" do
    metadata = finished_pr_metadata(
      "github_pull_request_statuses" => { PR => "merged" },
      "github_pull_request_ci_statuses" => {},
      "github_pull_request_goal_facts" => {
        PR => { "verification_section" => true, "verification_checked_boxes" => 1, "unchecked_boxes" => 0, "labels" => [] }
      }
    )

    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    assert_equal "met", check.verdict
  end

  # ---- a PR goal that was not ----

  test "a session with no recorded PR is unmet, and says so" do
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr"))

    assert_equal "unmet", check.verdict
    pr = check.criteria.find { |c| c.key == "pull_request_open" }
    assert_equal "unmet", pr.status
    assert_equal "No pull request is recorded for this session or any session it spawned", pr.detail
    # Nothing else can be judged without a PR, and is not claimed either way.
    assert_equal %w[unknown], (check.criteria - [ pr ]).map(&:status).uniq
  end

  test "failing CI is unmet" do
    metadata = finished_pr_metadata("github_pull_request_ci_statuses" => { PR => "fail" })
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    assert_equal "unmet", check.verdict
    assert_equal "unmet", statuses(check)["ci_green"]
    assert_equal "failing", check.criteria.find { |c| c.key == "ci_green" }.detail
  end

  test "a description with no Verification heading, an unchecked box, and no label is unmet on all three" do
    metadata = finished_pr_metadata(
      "github_pull_request_goal_facts" => {
        PR => { "verification_section" => false, "verification_checked_boxes" => 0, "unchecked_boxes" => 2, "labels" => [ "bug" ] }
      }
    )
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    assert_equal "unmet", check.verdict
    assert_equal "unmet", statuses(check)["verification_section"]
    assert_equal "unmet", statuses(check)["verification_boxes_checked"]
    assert_equal "2 unchecked boxes", check.criteria.find { |c| c.key == "verification_boxes_checked" }.detail
    assert_equal "unmet", statuses(check)["ready_to_merge_label"]
  end

  test "a Verification section with no checked box is unmet" do
    metadata = finished_pr_metadata(
      "github_pull_request_goal_facts" => {
        PR => { "verification_section" => true, "verification_checked_boxes" => 0, "unchecked_boxes" => 0, "labels" => [ "ready to merge" ] }
      }
    )
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    assert_equal "unmet", statuses(check)["verification_boxes_checked"]
  end

  test "a PR closed without merging does not satisfy the goal" do
    metadata = finished_pr_metadata("github_pull_request_statuses" => { PR => "closed" })
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    assert_equal "unmet", check.verdict
    assert_equal "Every recorded pull request was closed without merging",
      check.criteria.find { |c| c.key == "pull_request_open" }.detail
  end

  test "with two live PRs, one failing CI makes the criterion unmet and names that PR" do
    metadata = finished_pr_metadata.merge(
      "github_pull_request_urls" => [ PR, OTHER_PR ],
      "github_pull_request_statuses" => { PR => "open", OTHER_PR => "open" },
      "github_pull_request_ci_statuses" => { PR => "pass", OTHER_PR => "fail" }
    )
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    ci = check.criteria.find { |c| c.key == "ci_green" }
    assert_equal "unmet", ci.status
    assert_equal "owner/other#9: failing", ci.detail
  end

  # ---- a PR goal that cannot be decided yet ----

  test "CI still running is pending, not unmet" do
    metadata = finished_pr_metadata("github_pull_request_ci_statuses" => { PR => "pending" })
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    assert_equal "pending", check.verdict
    assert_equal "pending", statuses(check)["ci_green"]
  end

  test "a PR recorded but not yet read from GitHub is pending" do
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: { "github_pull_request_urls" => [ PR ] }))

    assert_equal "pending", check.verdict
    assert_equal "pending", statuses(check)["pull_request_open"]
  end

  test "no CI reading is unknown, and keeps the verdict from reading met" do
    metadata = finished_pr_metadata("github_pull_request_ci_statuses" => {})
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: metadata))

    assert_equal "unknown", statuses(check)["ci_green"]
    assert_equal "pending", check.verdict
  end

  test "a running session's check is provisional" do
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", status: :running))

    assert check.provisional
  end

  test "a waiting session's check is provisional too: it has not come to rest" do
    check = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", status: :waiting))

    assert check.provisional
  end

  # ---- PRs a spawned session recorded ----

  test "a session with no PR of its own is judged on the PR its child recorded" do
    router = make_session(goal: "open-reviewed-green-pr", status: :archived)
    child = make_session(goal: "open-reviewed-green-pr", status: :archived,
                         custom_metadata: finished_pr_metadata("github_pull_request_statuses" => { PR => "merged" }))
    child.update!(parent_session_id: router.id)

    check = GoalCheck.for(router)

    assert_equal "met", check.verdict
    assert_equal [ child.id ], check.delegated_session_ids
    assert_equal "owner/repo#7 merged (via session ##{child.id})", check.criteria.first.detail
    assert_equal "2026-09-11T12:00:00Z", check.to_h[:observed_at]
  end

  test "a grandchild's PR counts, and an unmet one is reported as unmet" do
    router = make_session(goal: "open-reviewed-green-pr")
    middle = make_session(goal: "open-reviewed-green-pr")
    middle.update!(parent_session_id: router.id)
    leaf = make_session(goal: "open-reviewed-green-pr",
                        custom_metadata: finished_pr_metadata("github_pull_request_ci_statuses" => { PR => "fail" }))
    leaf.update!(parent_session_id: middle.id)

    check = GoalCheck.for(router)

    assert_equal [ leaf.id ], check.delegated_session_ids
    assert_equal "unmet", statuses(check)["ci_green"]
  end

  test "a session's own PR wins over its children's" do
    parent = make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata)
    make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata(OTHER_PR))
      .update!(parent_session_id: parent.id)

    check = GoalCheck.for(parent)

    assert_not check.delegated?
    assert_equal "owner/repo#7 open", check.criteria.first.detail
  end

  test "with no PR anywhere below it, the detail says so" do
    router = make_session(goal: "open-reviewed-green-pr")
    make_session(goal: "open-reviewed-green-pr").update!(parent_session_id: router.id)

    check = GoalCheck.for(router)

    assert_equal "unmet", statuses(check)["pull_request_open"]
    assert_match(/any session it spawned/, check.criteria.first.detail)
    assert_empty check.delegated_session_ids
  end

  test "the fan-out cap applies per parent, so a big fleet parent cannot crowd out another parent's child" do
    fleet = make_session(goal: "open-reviewed-green-pr")
    3.times { make_session(goal: "open-reviewed-green-pr").update!(parent_session_id: fleet.id) }
    router = make_session(goal: "open-reviewed-green-pr")
    child = make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata)
    child.update!(parent_session_id: router.id)

    original = GoalCheck::DELEGATION_FAN_OUT
    silence_warnings { GoalCheck.const_set(:DELEGATION_FAN_OUT, 2) }
    delegates = GoalCheck.delegated_pull_requests([ fleet.id, router.id ])

    assert_equal 2, delegates.fetch(fleet.id).size
    assert_equal [ child.id ], delegates.fetch(router.id).map(&:id)
  ensure
    silence_warnings { GoalCheck.const_set(:DELEGATION_FAN_OUT, original) } if original
  end

  test "a requested session under another requested session is read for both, once each" do
    top = make_session(goal: "open-reviewed-green-pr")
    middle = make_session(goal: "open-reviewed-green-pr")
    middle.update!(parent_session_id: top.id)
    leaf = make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata)
    leaf.update!(parent_session_id: middle.id)

    delegates = GoalCheck.delegated_pull_requests([ top.id, middle.id ])

    assert_equal [ middle.id, leaf.id ], delegates.fetch(top.id).map(&:id)
    assert_equal [ leaf.id ], delegates.fetch(middle.id).map(&:id)
  end

  test "a fourth generation is past the depth bound" do
    parent = make_session(goal: "open-reviewed-green-pr")
    chain = 3.times.inject(parent) do |above, _|
      make_session(goal: "open-reviewed-green-pr").tap { |s| s.update!(parent_session_id: above.id) }
    end
    make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata).update!(parent_session_id: chain.id)

    assert_equal "unmet", statuses(GoalCheck.for(parent))["pull_request_open"]
  end

  test "observed_at is the stalest reading among the delegated PRs" do
    router = make_session(goal: "open-reviewed-green-pr")
    make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata)
      .update!(parent_session_id: router.id)
    make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata(OTHER_PR,
      "poller_last_polled_at" => { "github_pr_poller" => "2026-09-10T08:00:00Z" })).update!(parent_session_id: router.id)

    assert_equal "2026-09-10T08:00:00Z", GoalCheck.for(router).to_h[:observed_at]
  end

  test "a batch-loaded delegate list gives the same answer without querying" do
    router = make_session(goal: "open-reviewed-green-pr")
    child = make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata)
    child.update!(parent_session_id: router.id)

    delegates = GoalCheck.delegated_pull_requests([ router.id ])
    assert_equal [ child.id ], delegates.fetch(router.id).map(&:id)

    Session.expects(:where).never
    assert_equal "met", GoalCheck.for(router, delegates: delegates.fetch(router.id)).verdict
  end

  # ---- codebase-question ----

  test "codebase-question is met when the session opened no PR" do
    check = GoalCheck.for(make_session(goal: "codebase-question"))

    assert_equal "met", check.verdict
  end

  test "codebase-question is unmet when the session opened a PR" do
    check = GoalCheck.for(make_session(goal: "codebase-question", custom_metadata: { "github_pull_request_urls" => [ PR ] }))

    assert_equal "unmet", check.verdict
    assert_equal "Opened owner/repo#7", check.criteria.first.detail
  end

  test "codebase-question is not charged with a PR a child opened" do
    parent = make_session(goal: "codebase-question")
    make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata).update!(parent_session_id: parent.id)

    assert_equal "met", GoalCheck.for(parent).verdict
  end

  # ---- the hash every surface serializes ----

  test "to_h carries the verdict, each criterion and the advisory note" do
    hash = GoalCheck.for(make_session(goal: "open-reviewed-green-pr", custom_metadata: finished_pr_metadata)).to_h

    assert_equal "open-reviewed-green-pr", hash[:goal_id]
    assert_equal "met", hash[:verdict]
    assert_equal "2026-09-11T12:00:00Z", hash[:observed_at]
    assert_equal [], hash[:delegated_session_ids]
    assert_equal 5, hash[:criteria].size
    assert_equal %i[key label status detail], hash[:criteria].first.keys
    assert_equal GoalCheck::NOT_CHECKED_NOTE, hash[:note]
  end
end
