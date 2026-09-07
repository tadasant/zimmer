# frozen_string_literal: true

require "test_helper"

# The Restart control appears in exactly the states a human may restart from —
# at all three sites that render it.
#
# `restart` is one operation behind three doors, and until zimmer#830 the web
# door was strictly narrower than the other two: `SessionsController#restart`
# re-derived its entry condition as `failed?`, so a session stranded in
# `needs_input` could be restarted by an agent through MCP `action_session` and
# by a script through `POST /api/v1/sessions/:id/restart`, and by a person not at
# all — no affordance, and a refusal behind it if there had been one.
#
# All three render sites now ask Session#restartable_by_hand?, so they cannot
# drift from the controller or from each other. What this pins is which states
# each site offers the control in, and that a restart from `needs_input` — a
# takeover rather than a recovery — asks before it fires.
class RestartAffordanceContractTest < ActionDispatch::IntegrationTest
  # Every state a session can be in, and whether the Restart control belongs.
  RESTARTABLE = {
    failed: true,
    needs_input: true,
    waiting: false,
    running: false,
    archived: false
  }.freeze

  def session_in(status)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      title: "Restart affordance #{status}",
      status: status,
      session_id: SecureRandom.uuid
    )
  end

  def render_session_partial(partial, session)
    SessionsController.render(
      partial: "sessions/#{partial}",
      locals: { agent_session: session },
      assigns: { session: session }
    )
  end

  RESTARTABLE.each do |status, offered|
    test "the session header offers Restart for a #{status} session: #{offered}" do
      session = session_in(status)
      html = render_session_partial("session_header_actions", session)

      if offered
        assert_includes html, "/sessions/#{session.id}/restart"
      else
        refute_includes html, "/sessions/#{session.id}/restart"
      end
    end

    test "the session card offers Restart for a #{status} session: #{offered}" do
      session = session_in(status)
      html = render_session_partial("session_card", session)

      if offered
        assert_includes html, "/sessions/#{session.id}/restart"
      else
        refute_includes html, "/sessions/#{session.id}/restart"
      end
    end

    # The joystick's sheet is the mobile twin of the header. Its Restart button
    # carries no URL of its own — the controller reads `data-restart-url` off the
    # root element, which is rendered unconditionally — so what is gated is the
    # button, identified by its petal key.
    test "the mobile joystick offers Restart for a #{status} session: #{offered}" do
      session = session_in(status)
      html = render_session_partial("mobile_joystick", session)

      if offered
        assert_includes html, 'data-petal-key="restart"'
      else
        refute_includes html, 'data-petal-key="restart"'
      end
    end
  end

  # A failed session has stopped and Restart means what it has always meant, so
  # it fires on the click. `needs_input` is the state zimmer#830 opened up, and
  # there the same button resumes a live session and enqueues a turn nobody asked
  # for — so it says so first, at every site.
  test "restarting a failed session asks nothing" do
    session = session_in(:failed)

    refute_includes render_session_partial("session_header_actions", session), "turbo-confirm"
    refute_includes render_session_partial("session_card", session), "turbo-confirm"
    assert_includes render_session_partial("mobile_joystick", session), 'data-restart-confirm=""'
  end

  test "restarting a needs_input session with a conversation confirms it is a takeover" do
    session = session_in(:needs_input)

    assert_match(/data-turbo-confirm="[^"]*paused, not failed/, render_session_partial("session_header_actions", session))
    assert_match(/data-turbo-confirm="[^"]*paused, not failed/, render_session_partial("session_card", session))
    assert_match(/data-restart-confirm="[^"]*paused, not failed/, render_session_partial("mobile_joystick", session))
  end

  # The case that motivated the issue: paused into `needs_input` with nothing to
  # prompt into. Restart there is not a continue prompt at all — it throws the
  # setup away and re-runs the pipeline — so it says that instead.
  test "restarting a never-run needs_input session confirms the pipeline re-runs" do
    session = session_in(:needs_input)
    session.update!(session_id: nil)

    assert session.needs_restart_from_scratch?
    assert_match(/data-turbo-confirm="[^"]*setup never finished/, render_session_partial("session_header_actions", session))
    assert_match(/data-turbo-confirm="[^"]*setup never finished/, render_session_partial("session_card", session))
    assert_match(/data-restart-confirm="[^"]*setup never finished/, render_session_partial("mobile_joystick", session))
  end
end
