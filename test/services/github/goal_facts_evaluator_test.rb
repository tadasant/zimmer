require "test_helper"
require "mocha/minitest"

class Github::GoalFactsEvaluatorTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/owner/repo/pull/5".freeze
  REF = Github::PrRef.parse(PR_URL)

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(goal:)
    Session.create!(
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      goal: goal,
      git_root: "https://github.com/owner/repo.git",
      branch: "main",
      custom_metadata: { "github_pull_request_urls" => [ PR_URL ] }
    )
  end

  def snapshot(body:, labels: [])
    Github::PrSnapshot.new(ref: REF, state: "OPEN", merged_at: nil, mergeable: "MERGEABLE", body: body, labels: labels)
  end

  def facts(body)
    Github::GoalFactsEvaluator.body_facts(body)
  end

  # ---- reading the description ----

  test "a Verification section with every box checked" do
    body = <<~MD
      ## Summary
      - [x] not under Verification, so not counted as a Verification box

      ## Verification
      - [x] CI green
      - [X] tests added
      * [x] reviewed
    MD

    assert_equal(
      { "verification_section" => true, "verification_checked_boxes" => 3, "unchecked_boxes" => 0 },
      facts(body)
    )
  end

  test "an unchecked box anywhere in the description is counted" do
    body = <<~MD
      ## Verification
      - [x] CI green

      ## Test plan
      - [ ] try it on staging
      1. [ ] and on a phone
    MD

    result = facts(body)
    assert_equal 2, result["unchecked_boxes"]
    assert_equal 1, result["verification_checked_boxes"], "a sibling heading ends the Verification section"
  end

  test "GitHub's CRLF line endings and a box inside a blockquote are read the same" do
    body = "## Verification\r\n- [x] CI green\r\n> - [ ] quoted, and still a checkbox\r\n"

    assert_equal(
      { "verification_section" => true, "verification_checked_boxes" => 1, "unchecked_boxes" => 1 },
      facts(body)
    )
  end

  test "a heading that leads with an emoji still names the section" do
    assert_equal true, facts("## ✅ Verification\n- [x] ok\n")["verification_section"]
    assert_equal false, facts("####### Verification\n")["verification_section"], "seven #s is not a heading"
  end

  test "a longer fence can quote a shorter one, and an unclosed comment hides the rest" do
    body = "````\n```\n- [ ] inside the outer fence\n```\n````\n## Verification\n- [x] ok\n<!-- left open\n- [ ] hidden by GitHub\n"

    assert_equal(
      { "verification_section" => true, "verification_checked_boxes" => 1, "unchecked_boxes" => 0 },
      facts(body)
    )
  end

  test "a description with no Verification heading says so" do
    assert_equal false, facts("Fixes the thing.\n\n- [x] done")["verification_section"]
  end

  test "a deeper heading inside Verification does not end it" do
    body = "## Verification\n### Unit\n- [x] passes\n### E2E\n- [x] recorded\n"

    assert_equal 2, facts(body)["verification_checked_boxes"]
  end

  test "text a reader would not see — code blocks and HTML comments — counts for nothing" do
    body = <<~MD
      <!-- template:
      ## Verification
      - [ ] fill me in
      -->
      ```markdown
      ## Verification
      - [ ] example
      ```
      Plain prose.
    MD

    assert_equal(
      { "verification_section" => false, "verification_checked_boxes" => 0, "unchecked_boxes" => 0 },
      facts(body)
    )
  end

  test "an issue reference is not a heading" do
    assert_equal false, facts("#88 Verification of goals")["verification_section"]
  end

  # ---- recording ----

  test "records facts for a session whose goal checks the description" do
    session = make_session(goal: "open-reviewed-green-pr")

    Github::GoalFactsEvaluator.new.evaluate(
      session, [ REF ], { PR_URL => snapshot(body: "## Verification\n- [x] ok", labels: [ "ready to merge" ]) }
    )

    assert_equal(
      { "verification_section" => true, "verification_checked_boxes" => 1, "unchecked_boxes" => 0, "labels" => [ "ready to merge" ] },
      session.reload.custom_metadata.dig("github_pull_request_goal_facts", PR_URL)
    )
  end

  test "records nothing for a free-text goal, which nothing would read" do
    session = make_session(goal: "Ship the fix and open a PR")

    Github::GoalFactsEvaluator.new.evaluate(session, [ REF ], { PR_URL => snapshot(body: "## Verification") })

    assert_nil session.reload.custom_metadata["github_pull_request_goal_facts"]
  end

  test "a PR this pass could not read keeps what was recorded" do
    session = make_session(goal: "open-reviewed-green-pr")
    recorded = { "verification_section" => true, "verification_checked_boxes" => 1, "unchecked_boxes" => 0, "labels" => [] }
    session.merge_custom_metadata!("github_pull_request_goal_facts" => { PR_URL => recorded })

    Github::GoalFactsEvaluator.new.evaluate(session, [ REF ], { PR_URL => nil })

    assert_equal recorded, session.reload.custom_metadata.dig("github_pull_request_goal_facts", PR_URL)
  end

  test "an unchanged reading does not write" do
    session = make_session(goal: "open-reviewed-green-pr")
    reading = snapshot(body: "## Verification\n- [x] ok")
    Github::GoalFactsEvaluator.new.evaluate(session, [ REF ], { PR_URL => reading })
    session.reload

    session.expects(:merge_custom_metadata!).never
    Github::GoalFactsEvaluator.new.evaluate(session, [ REF ], { PR_URL => reading })
  end
end
