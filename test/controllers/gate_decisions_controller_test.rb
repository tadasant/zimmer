# frozen_string_literal: true

require "test_helper"

# The browsable ledger. Two properties are worth holding this page to:
#
#   * It filters through GateDecisions::Filters and nothing else, so a question
#     asked here and the same question asked by `search_gate_decisions` cannot
#     come back with different answers.
#   * It renders an entry it has never seen the shape of, without dropping a key.
class GateDecisionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hold = create_decision(
      artifact_url: "https://github.com/tadasant/zimmer/pull/781",
      decided_at: Date.new(2026, 9, 1), decision: "hold",
      payload: {
        "pr" => "https://github.com/tadasant/zimmer/pull/781",
        "title" => "Move the gate decision ledgers into Postgres",
        "aligned" => true,
        "ratings" => { "implementation_risk" => "large" },
        "reason" => "Held. " + ("The browser surface authenticates nobody. " * 40)
      }
    )
    @merge = create_decision(
      surface: "strad", artifact_url: "https://github.com/tadasant/strad/pull/40",
      decided_at: Date.new(2026, 8, 20), decision: "auto-merge",
      payload: { "title" => "A strad change", "reason" => "Fine." }
    )
  end

  test "the ledger lists decisions newest first" do
    get gate_decisions_path

    assert_response :success
    assert_select "h1", "Gate Decisions"
    assert_operator response.body.index("pull/781"), :<, response.body.index("strad/pull/40"),
      "newest decided_at first"
  end

  test "every filter narrows through the shared filter object" do
    get gate_decisions_path(gate: GateDecision::ISSUE_WORK)
    assert_no_match "pull/781", response.body

    get gate_decisions_path(surface: "strad")
    assert_no_match "pull/781", response.body
    assert_match "strad/pull/40", response.body

    get gate_decisions_path(decision: "hold")
    assert_match "pull/781", response.body
    assert_no_match "strad/pull/40", response.body

    get gate_decisions_path(from: "2026-09-01")
    assert_match "pull/781", response.body
    assert_no_match "strad/pull/40", response.body

    get gate_decisions_path(query: "authenticates nobody")
    assert_match "pull/781", response.body
    assert_no_match "strad/pull/40", response.body
  end

  test "the artifact URL box is a substring search, not the exact match a gate asks for" do
    get gate_decisions_path(artifact_query: "781")

    assert_response :success
    assert_match "pull/781", response.body
    assert_no_match "strad/pull/40", response.body
  end

  test "the human-note filter finds the rare rows that carry one" do
    @merge.feedbacks.create!(verdict: "should-have-held", author: users(:tadasant).key,
                             channel: GateDecisionFeedback::WEB_UI, received_at: Date.new(2026, 8, 21))

    get gate_decisions_path(with_human_feedback: "1")

    assert_match "strad/pull/40", response.body
    assert_no_match "pull/781", response.body
  end

  test "a filter the ledger cannot honour says so rather than showing an empty ledger" do
    # The API answers 422; a page cannot, and "no results" is the one thing a
    # reader must not conclude from a typo in a hand-edited URL.
    get gate_decisions_path(gate: "nonsense")

    assert_response :success
    assert_match "Unknown gate", response.body
    assert_match "pull/781", response.body, "the ledger is shown unfiltered, not emptied"

    get gate_decisions_path(from: "not-a-date")
    assert_response :success
    assert_match "must be an ISO date", response.body
  end

  test "paging keeps the filters it is paging through" do
    get gate_decisions_path(decision: "hold", page: 2)

    assert_response :success
    assert_select "a", text: /Previous/ do |links|
      assert_match "decision=hold", links.first["href"]
    end
  end

  test "the detail page renders every key the gate wrote, in order, without a field list" do
    @hold.update_columns(payload: @hold.payload.merge(
      "a_key_invented_next_month" => { "nested" => [ "one", "two" ] }
    ))

    get gate_decision_path(@hold)

    assert_response :success
    # THE REGRESSION THIS GUARDS. A view built from a hardcoded list of field
    # names goes wrong by omission, silently, the first time a gate adds a key.
    assert_select "section#entry-a-key-invented-next-month" do
      assert_select "h2", "A key invented next month"
      assert_select "span", "one"
      assert_select "span", "two"
    end
    assert_select "section#entry-reason h2", "Reason"
    assert_select "section#entry-ratings h2", "Ratings"
  end

  test "the detail page skims the short fields and lists the long ones separately" do
    get gate_decision_path(@hold)

    assert_select "h2", "At a glance"
    assert_select "h2", "The reasoning"
    # `ratings` skims (four words); `reason` does not (many paragraphs). Neither
    # is named anywhere in the view.
    assert_select "aside a[href=?]", "#entry-reason"
    assert_select "aside a[href=?]", "#entry-ratings", false
  end

  test "the detail page shows the other ratings of the same artifact" do
    # Rows are append-only, so a re-rate is a NEW row and the earlier reading is
    # still live. Someone reading a hold has to see that a later row un-held it.
    later = create_decision(artifact_url: @hold.artifact_url, decided_at: Date.new(2026, 9, 2),
                            decision: "auto-merge", payload: { "reason" => "Base moved; re-rated." })

    get gate_decision_path(@hold)

    assert_match "This artifact was rated 2 times", response.body
    assert_select "a[href=?]", gate_decision_path(later)
  end

  test "the feedback form posts to the browser-only write path and does not claim a verified human" do
    get gate_decision_path(@hold)

    assert_select "form[action=?][method=?]", gate_decision_feedbacks_path(@hold), "post"
    assert_select "form[action=?] input[name=verdict]", gate_decision_feedbacks_path(@hold)
    assert_select "form[action=?] textarea[name=note]", gate_decision_feedbacks_path(@hold)
    # The copy must not imply the field is verified-human: Zimmer's browser
    # surface authenticates nobody (#371, #220).
    assert_no_match(/verified human/i, response.body)
    assert_match "authenticates nobody", response.body
  end

  test "feedback already on a decision is shown with its channel" do
    @hold.feedbacks.create!(verdict: "should-have-merged", note: "The CI failure was unrelated.",
                            author: users(:tadasant).key, channel: GateDecisionFeedback::WEB_UI,
                            received_at: Date.new(2026, 9, 2))

    get gate_decision_path(@hold)

    assert_match "should-have-merged", response.body
    assert_match "The CI failure was unrelated.", response.body
    assert_match users(:tadasant).display_name, response.body
    assert_match GateDecisionFeedback::WEB_UI, response.body
  end

  test "a promoted URL is only ever an href when it is one" do
    # `artifact_url` and `producing_session_url` are pulled out of prose a gate
    # wrote — GateDecisions::Entry calls the session key "free text ... usually a
    # URL, often a URL followed by a paragraph". So the column can hold a
    # paragraph, or a hostile scheme, and neither may become a live link.
    odd = create_decision(
      artifact_url: "javascript:alert(1)",
      producing_session_url: "https://zimmer.example.com/sessions/9 — and then it stalled"
    )

    get gate_decision_path(odd)

    assert_response :success
    assert_select "a[href^=?]", "javascript", false
    assert_select "a[href*=?]", "and then it stalled", false
    assert_match "javascript:alert(1)", response.body, "shown as text rather than dropped"
    assert_match "and then it stalled", response.body

    get gate_decisions_path(artifact_query: "javascript")

    assert_select "a[href^=?]", "javascript", false
  end

  test "a decision whose entry is empty renders rather than blowing up" do
    bare = create_decision(artifact_url: nil, payload: {})

    get gate_decision_path(bare)

    assert_response :success
    assert_match "carries no entry body", response.body
  end

  test "an unknown decision is a 404, not a 500" do
    get gate_decision_path(id: 0)

    assert_response :not_found
  end

  test "the empty ledger says where the rows come from instead of nothing" do
    GateDecisionFeedback.delete_all
    GateDecision.delete_all

    get gate_decisions_path

    assert_match "ImportGateDecisionLedgers", response.body
  end

  private

  def create_decision(**overrides)
    GateDecision.create!({
      gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: "https://github.com/tadasant/zimmer/pull/1",
      decided_at: Date.new(2026, 8, 1), decision: "auto-merge", payload: {}
    }.merge(overrides))
  end
end
