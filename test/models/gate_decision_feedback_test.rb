# frozen_string_literal: true

require "test_helper"

class GateDecisionFeedbackTest < ActiveSupport::TestCase
  setup do
    @decision = GateDecision.create!(gate: GateDecision::ISSUE_WORK, surface: "zimmer",
                                     artifact_url: "https://github.com/tadasant/zimmer/issues/530",
                                     decided_at: Date.new(2026, 8, 19), decision: "hold",
                                     recorded_via: GateDecision::IMPORT, payload: { "title" => "An issue" })
  end

  test "a recorded note cannot be edited into saying something else" do
    note = @decision.feedbacks.create!(verdict: "should-have-proceeded", note: "agent-filed is not a reason to hold.",
                                       author: "tadasant", channel: GateDecisionFeedback::WEB_UI)

    assert_raises(ActiveRecord::ReadOnlyRecord) { note.update!(verdict: "correct-as-rated") }
    assert_equal "should-have-proceeded", note.reload.verdict
  end

  test "a recorded note cannot be deleted to make a gate look better" do
    note = @decision.feedbacks.create!(verdict: "should-have-held", author: "tadasant",
                                       channel: GateDecisionFeedback::WEB_UI)

    assert_raises(ActiveRecord::ReadOnlyRecord) { note.destroy }
    assert GateDecisionFeedback.exists?(note.id)
  end

  test "a note from the browser must name its author" do
    note = @decision.feedbacks.new(verdict: "should-have-held", channel: GateDecisionFeedback::WEB_UI)

    assert_not note.valid?
    assert_includes note.errors[:author], "can't be blank"
  end

  test "an imported note may have no author, because the source did not always record one" do
    note = @decision.feedbacks.new(verdict: "should-have-held", channel: GateDecisionFeedback::IMPORTED)

    assert note.valid?, note.errors.full_messages.to_sentence
  end

  test "there is no machine channel" do
    assert_equal %w[web_ui imported], GateDecisionFeedback::CHANNELS

    note = @decision.feedbacks.new(verdict: "should-have-held", channel: "mcp", author: "some_agent")
    assert_not note.valid?
    assert_includes note.errors[:channel], "is not included in the list"
  end
end
