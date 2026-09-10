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

  # The classes on the card's Restart submit button, which is how the two
  # placements are told apart. Returned rather than asserted on inline so a
  # failure prints one attribute instead of a whole rendered card.
  def card_restart_button_classes(session)
    html = render_session_partial("session_card", session)
    html[%r{action="/sessions/#{session.id}/restart".*?<button[^>]*\sclass="([^"]+)"}m, 1]
  end

  # Where the card puts the control, which is not the same for both states. The
  # footer row has a width budget and #607 spent it — a multi-PR card already fits
  # 84 + 277 into 311px at a 343px phone card, so a fifth control wraps the row
  # onto a second line. `failed` therefore keeps the prominent footer button it
  # has always had, and `needs_input` gets a row in the overflow menu. Both post
  # to the same action, which is what the status matrix above asserts.
  test "the card gives a failed session the footer button" do
    classes = card_restart_button_classes(session_in(:failed))

    assert classes, "no Restart button on a failed session's card"
    assert_includes classes, "border-green-300", "a failed session keeps the prominent footer button"
    refute_includes classes, "px-3 py-2.5", "a failed session's Restart must not be demoted into the menu"
  end

  test "the card gives a paused session an overflow-menu row instead" do
    classes = card_restart_button_classes(session_in(:needs_input))

    assert classes, "no Restart control on a paused session's card"
    assert_includes classes, "w-full flex items-center gap-2 px-3 py-2.5",
      "a paused session's Restart belongs in the overflow menu, which costs the footer row no width"
    refute_includes classes, "border-green-300"
  end

  # A failed session has stopped and Restart means what it has always meant, so
  # it fires on the click. `needs_input` is the state zimmer#830 opened up, and
  # there the same button resumes a live session and enqueues a turn nobody asked
  # for — so it says so first, at every site.
  test "restarting a failed session asks nothing" do
    session = session_in(:failed)

    refute_includes render_session_partial("session_header_actions", session), "turbo-confirm"
    refute_includes render_session_partial("session_card", session), "turbo-confirm"

    # The joystick's attribute is always rendered; what matters is that it carries
    # nothing, because joystick-menu#_commit fires straight through on a falsy one.
    joystick = render_session_partial("mobile_joystick", session)
    assert_empty joystick[/data-restart-confirm="([^"]*)"/, 1].to_s,
      "a failed session's sheet button must not raise a dialog"
  end

  test "restarting a needs_input session with a conversation confirms it is a takeover" do
    session = session_in(:needs_input)

    assert_match(/data-turbo-confirm="[^"]*paused, not failed/, render_session_partial("session_header_actions", session))
    assert_match(/data-turbo-confirm="[^"]*paused, not failed/, render_session_partial("session_card", session))
    assert_match(/data-restart-confirm="[^"]*paused, not failed/, render_session_partial("mobile_joystick", session))
  end

  # The third branch: a turn that died before its prompt reached the agent parks in
  # `needs_input` with a PRE_PROMPT_FAILURE_REASONS reason, and restarting re-sends
  # that prompt rather than an automated continue nudge. The dialog says so, because
  # SessionsHelper#restart_confirmation branches in the controller's own order.
  test "restarting a needs_input session whose prompt was never delivered says the prompt is re-sent" do
    session = session_in(:needs_input)
    session.update!(metadata: {
      "clone_path" => "/tmp/a-clone", "working_directory" => "/tmp/a-clone",
      "failure_reason" => "unstarted_turn_not_recoverable"
    })

    assert session.failed_before_initial_prompt?
    assert_not session.needs_restart_from_scratch?
    assert_match(/data-turbo-confirm="[^"]*sends that original prompt again/,
      render_session_partial("session_header_actions", session))
  end

  # A session blocked on an elicitation is `needs_input` and is NOT offered the
  # control at any of the three sites: its agent is alive and the thing that
  # unblocks it is the answer form on this very page.
  test "no site offers Restart for a session blocked on an elicitation" do
    session = session_in(:needs_input)
    session.merge_metadata!("blocked_on_elicitation" => true)

    refute_includes render_session_partial("session_header_actions", session), "/sessions/#{session.id}/restart"
    refute_includes render_session_partial("session_card", session), "/sessions/#{session.id}/restart"
    refute_includes render_session_partial("mobile_joystick", session), 'data-petal-key="restart"'
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
