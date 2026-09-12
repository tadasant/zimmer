# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Merge button's write: a human's click turned into a message the session
# holding the PR can act on.
#
# This is the one sanctioned path for an agent to merge its own work, so what is
# asserted here is as much about the PROVENANCE as about the delivery.
class Sessions::AuthorizeMergeTest < ActiveSupport::TestCase
  URL = "https://github.com/o/r/pull/7"

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.delete_all
  end

  def session_with_green_pr(status: :needs_input)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      status: status,
      custom_metadata: {
        "github_pull_request_urls" => [ URL ],
        "github_pull_request_statuses" => { URL => "open" },
        "github_pull_request_ci_statuses" => { URL => "pass" }
      }
    )
  end

  test "a green PR on a parked session is authorized and the message sent immediately" do
    session = session_with_green_pr
    session.expects(:deliver_follow_up!).with { |prompt, _| AutomatedPrompts.merge_authorization?(prompt) }.once
    Session.stubs(:find).returns(session)

    result = Sessions::AuthorizeMerge.call(session: session)

    assert result.sent?
    assert_equal URL, result.pr_url
  end

  test "the message names the PR, the surface, and carries the authorization marker" do
    message = AutomatedPrompts.merge_authorization_message(URL)

    assert_includes message, AutomatedPrompts::MERGE_AUTHORIZATION_MARKER
    assert_includes message, URL
    assert_includes message, "Merge button"
    assert_match(/merge conflicts/i, message)
    assert_match(/self-archive/i, message)
  end

  # A session mid-turn is doing work nobody asked to abort, so the authorization
  # waits for the turn boundary rather than interrupting.
  test "a running session gets the authorization queued rather than interrupted" do
    session = session_with_green_pr(status: :running)

    result = Sessions::AuthorizeMerge.call(session: session)

    assert result.sent?
    queued = session.enqueued_messages.pending.last
    assert AutomatedPrompts.merge_authorization?(queued.content)
    assert_equal "caller", queued.origin,
      "a human is waiting on this message, so it is not one of the self-addressed automated origins"
  end

  test "a second click does not send a second copy" do
    session = session_with_green_pr(status: :running)

    first = Sessions::AuthorizeMerge.call(session: session)
    second = Sessions::AuthorizeMerge.call(session: session)

    assert first.sent?
    assert_equal :already_sent, second.outcome
    assert second.ok?
    assert_equal 1, session.enqueued_messages.count, "a double-click must not stack two authorizations"
  end

  test "the authorization is recorded per PR url, so a later PR can still be merged" do
    session = session_with_green_pr(status: :running)
    Sessions::AuthorizeMerge.call(session: session)

    assert Sessions::AuthorizeMerge.authorized_at(session.reload, URL).present?

    later = "https://github.com/o/r/pull/8"
    session.update!(custom_metadata: session.custom_metadata.merge(
      "github_pull_request_urls" => [ URL, later ],
      "github_pull_request_statuses" => { URL => "merged", later => "open" },
      "github_pull_request_ci_statuses" => { later => "pass" }
    ))

    assert_nil Sessions::AuthorizeMerge.authorized_at(session, later)
    assert Sessions::AuthorizeMerge.call(session: session).sent?
  end

  test "a PR that is not open and green is refused with the reason" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git", prompt: "Test", status: :needs_input,
      custom_metadata: {
        "github_pull_request_urls" => [ URL ],
        "github_pull_request_statuses" => { URL => "open" },
        "github_pull_request_ci_statuses" => { URL => "fail" }
      }
    )

    result = Sessions::AuthorizeMerge.call(session: session)

    assert_equal :not_mergeable, result.outcome
    assert_not result.ok?
    assert_match(/CI is fail/, result.message)
    assert_equal 0, session.enqueued_messages.count
  end

  test "a session with no PR is refused" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :needs_input)

    result = Sessions::AuthorizeMerge.call(session: session)

    assert_equal :not_mergeable, result.outcome
    assert_match(/no PR/, result.message)
  end

  # A failed send must leave the button clickable again, not brick it on a
  # marker for a message that was never delivered.
  test "a failed delivery clears the authorization marker" do
    session = session_with_green_pr(status: :running)
    Sessions::AuthorizeMerge.any_instance.stubs(:deliver_automated_message).returns(false)

    result = Sessions::AuthorizeMerge.call(session: session)

    assert_equal :undeliverable, result.outcome
    assert_nil Sessions::AuthorizeMerge.authorized_at(session.reload, URL)
  end
end
