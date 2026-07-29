require "application_system_test_case"

# The session page is the only surface a user actually looks at when a session
# stops making progress. Before this banner, a session parked for an exhausted
# account pool showed nothing but the runtime's own "Not logged in · Please run
# /login" text — no cause, and no sign it would come back on its own.
class AuthOutageBannerTest < ApplicationSystemTestCase
  def parked_session(reason:)
    Session.create!(
      prompt: "Test prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: {
        "auth_outage_reason" => reason,
        "auth_outage_parked_at" => Time.current.iso8601,
        "auth_outage_retry_at" => 1.hour.from_now.utc.iso8601
      }
    )
  end

  test "a quota-exhausted session explains the outage and the automatic retry" do
    visit session_path(parked_session(reason: AuthOutageParkService::QUOTA_EXHAUSTED))

    assert_text "Quota exceeded across all accounts"
    assert_text "there is nothing to rotate into"
    assert_text "will resume automatically"
  end

  test "an auth-outage session names the login failure rather than the raw CLI text" do
    visit session_path(parked_session(reason: AuthOutageParkService::AUTH_UNRECOVERABLE))

    assert_text "No usable login available"
    assert_text "re-injecting credentials did not fix it"
  end

  test "a healthy session shows no outage banner" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    assert_no_text "Quota exceeded across all accounts"
    assert_no_text "No usable login available"
  end
end
