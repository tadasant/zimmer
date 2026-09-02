# frozen_string_literal: true

require "test_helper"

# The browser boundary. Everything here is about one property: this is the ONLY
# way a `web_ui` feedback row comes into existence on a live system, the author
# is resolved from the boundary rather than from the request, and the row cannot
# be edited or removed afterwards. The boundary is browser-vs-API-key, not
# human-vs-agent — see GateDecisionFeedback.
class GateDecisionFeedbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @decision = GateDecision.create!(
      gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: "https://github.com/tadasant/zimmer/pull/1",
      decided_at: Date.new(2026, 8, 15), decision: "auto-merge", payload: { "reason" => "fine" }
    )
  end

  test "records a note and attributes it to the admin, not to anything in the request" do
    post gate_decision_feedbacks_path(@decision),
      params: { verdict: "should-have-held", note: "This should not have merged.",
                received_at: "2026-08-16", author: "someone-else" }

    assert_redirected_to root_path
    feedback = @decision.feedbacks.sole
    assert_equal "should-have-held", feedback.verdict
    assert_equal "This should not have merged.", feedback.note
    assert_equal Date.new(2026, 8, 16), feedback.received_at
    assert_equal users(:tadasant).key, feedback.author, "the author comes from User.admin"
    assert_equal GateDecisionFeedback::WEB_UI, feedback.channel
  end

  test "an undated note is dated today rather than refused" do
    post gate_decision_feedbacks_path(@decision), params: { verdict: "mischaracterized" }

    assert_equal Date.current, @decision.feedbacks.sole.received_at
  end

  test "a blank verdict is refused and nothing is written" do
    post gate_decision_feedbacks_path(@decision), params: { verdict: "  ", note: "n" }

    assert_empty @decision.feedbacks
    assert_redirected_to root_path
  end

  test "the JSON form answers with the record it made" do
    post gate_decision_feedbacks_path(@decision), params: { verdict: "should-have-merged" }, as: :json

    assert_response :created
    assert_equal @decision.id, response.parsed_body["gate_decision_id"]
  end

  test "a note is append-only once written" do
    post gate_decision_feedbacks_path(@decision), params: { verdict: "should-have-held" }
    feedback = @decision.feedbacks.sole

    assert_raises(ActiveRecord::ReadOnlyRecord) { feedback.update!(verdict: "should-have-merged") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { feedback.destroy }
    assert_equal "should-have-held", feedback.reload.verdict
  end

  test "with no admin in the roster nothing is attributed and nothing is recorded" do
    User.stub(:admin, nil) do
      post gate_decision_feedbacks_path(@decision), params: { verdict: "should-have-held" }
    end

    assert_empty @decision.feedbacks
    assert_redirected_to root_path
  end

  test "an unknown decision is a 404, not a stray row" do
    post gate_decision_feedbacks_path(999_999), params: { verdict: "should-have-held" }

    assert_response :not_found
    assert_equal 0, GateDecisionFeedback.count
  end
end
