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

  # Two requests landing together each loaded their own copy of the session before
  # either wrote. The claim has to be re-read under the row lock, or both pass the
  # check and two merge messages go out.
  test "a claim made through a stale copy of the session does not send a second message" do
    first_copy = session_with_green_pr(status: :running)
    stale_copy = Session.find(first_copy.id)

    assert Sessions::AuthorizeMerge.call(session: first_copy).sent?
    second = Sessions::AuthorizeMerge.call(session: stale_copy)

    assert_equal :already_sent, second.outcome
    assert_equal 1, first_copy.enqueued_messages.count
  end

  # The message tells the agent to come back to needs_input when it cannot merge.
  # If the marker never cleared, that row would read "Merge sent" forever and the
  # server would refuse the one click that could retry.
  test "an authorization the session came back to rest from without merging offers Merge again" do
    session = session_with_green_pr(status: :running)
    assert Sessions::AuthorizeMerge.call(session: session).sent?

    # It took the turn, did not merge, and parked for the human.
    session.enqueued_messages.pending.update_all(status: "sent")
    session.update_columns(status: Session.statuses[:needs_input],
                           transcript_line_count: session.transcript_line_count + 12,
                           transcript_byte_size: 900)
    session.reload

    assert_nil Sessions::AuthorizeMerge.authorized_at(session, URL),
      "a session back at rest after the merge turn must be offered Merge again"

    session.stubs(:deliver_follow_up!)
    assert Sessions::AuthorizeMerge.call(session: session).sent?
  end

  # A session that came to rest from OTHER work before the queued authorization
  # drained has not answered it yet, so it must keep reading "Merge sent".
  test "an authorization still queued undelivered is live even once the session is at rest" do
    session = session_with_green_pr(status: :running)
    assert Sessions::AuthorizeMerge.call(session: session).sent?

    session.update_columns(status: Session.statuses[:needs_input],
                           transcript_line_count: session.transcript_line_count + 12,
                           transcript_byte_size: 900)
    session.reload

    assert Sessions::AuthorizeMerge.authorized_at(session, URL).present?
  end

  # A click on a session that has not moved since is not a failure to act on.
  test "an authorization on a session that has not taken a turn yet stays live" do
    session = session_with_green_pr(status: :needs_input)
    session.stubs(:deliver_follow_up!)
    assert Sessions::AuthorizeMerge.call(session: session).sent?

    assert Sessions::AuthorizeMerge.authorized_at(session.reload, URL).present?
  end
end
