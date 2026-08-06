require "application_system_test_case"

# An approval request that ends without a human answer leaves nothing else on
# screen: the elicitation banner is gone, and the session sits parked in
# needs_input reading as merely idle — the "phantom blocked" state. This asserts
# the session page says which of the two endings happened, in words that tell the
# user whether the agent carried on or is waiting on them.
class LostElicitationBannerTest < ApplicationSystemTestCase
  def session_with_lost_elicitation(reason:, **overrides)
    Session.create!({
      title: "Deploy the staging stack",
      prompt: "Ship it",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: {
        "lost_elicitation" => {
          "reason" => reason,
          "at" => Time.current.iso8601,
          "request_id" => "req-abc123",
          "summary" => "op_read: Reveal the production database password"
        }
      }
    }.merge(overrides))
  end

  test "an expired approval request says the agent continued without it" do
    visit session_path(session_with_lost_elicitation(reason: "expired"))

    assert_text "Approval request expired"
    assert_text "Nobody answered before the request timed out"
    assert_text "op_read: Reveal the production database password"
  end

  test "a lost round-trip tells the user the session is no longer blocked on it" do
    visit session_path(session_with_lost_elicitation(reason: "stranded"))

    assert_text "Approval request lost"
    assert_text "reply below to tell the agent how to proceed"
  end

  test "a session with no lost round-trip on record shows no banner" do
    session = Session.create!(
      title: "Healthy session",
      prompt: "Ship it",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    assert_no_text "Approval request expired"
    assert_no_text "Approval request lost"
  end

  # The phone-width geometry of this banner (and of the approval banner's now
  # three-button row) is pinned in MobileHorizontalOverflowTest, which runs both
  # overflow probes against the real session page.
end
