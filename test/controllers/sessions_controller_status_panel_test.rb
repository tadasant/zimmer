# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Status panel and the collapsed Transcript panel on the session detail
# screen — four sections in one card, only Status expanded.
class SessionsControllerStatusPanelTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    # A real directory, because the panel and the regenerate action both ask
    # whether there is still a clone to fork — see
    # SessionStatusSummaryGenerator.unavailable_reason.
    @clone_path = Dir.mktmpdir("status-panel-clone")

    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "Ship the thing",
      metadata: { "clone_path" => @clone_path },
      transcript: [
        { "type" => "user", "message" => { "role" => "user", "content" => "Ship the thing" }, "timestamp" => "2026-08-01T10:00:00Z" },
        { "type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "Opened the PR" } ] }, "timestamp" => "2026-08-01T10:00:01Z" }
      ].map { |l| JSON.generate(l) }.join("\n") + "\n"
    )
  end

  teardown do
    FileUtils.remove_entry(@clone_path) if @clone_path && File.directory?(@clone_path)
    Mocha::Mockery.instance.teardown
  end

  test "the four panels render in one group, Status first and always expanded" do
    get session_url(@session)

    assert_response :success
    assert_select "#session_#{@session.id}_panels" do
      assert_select "#session_#{@session.id}_status_panel"
      assert_select "#session_#{@session.id}_provenance"
      assert_select "details summary", text: /Transcript/
    end
    assert_select "#session_#{@session.id}_status_panel details", 0, "Status is not a disclosure"
  end

  test "the transcript is a details disclosure that is closed by default" do
    get session_url(@session)

    assert_response :success
    assert_select "details[data-controller='transcript-panel']" do
      assert_select "#timeline-container"
    end
    assert_select "details[data-controller='transcript-panel'][open]", 0
  end

  test "transcript messages carry stable anchor ids for the summary to link to" do
    get session_url(@session)

    assert_response :success
    assert_select "#message-0"
    assert_select "#message-1"
  end

  test "with no summary the panel says so and offers to generate one" do
    get session_url(@session)

    assert_response :success
    assert_match "No summary yet", response.body
    assert_select "form[action=?]", regenerate_status_summary_session_path(@session)
  end

  test "a current summary renders its markdown links and no staleness warning" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: Time.current,
      transcript_line_count: @session.transcript_line_count,
      summary: "The PR is [open](https://github.com/test/repo/pull/1) and CI is green."
    )

    get session_url(@session)

    assert_response :success
    assert_select "#session_#{@session.id}_status_panel" do
      assert_select "a[href='https://github.com/test/repo/pull/1']"
    end
    assert_no_match(/messages since summary generated/, response.body)
  end

  # A link into this session's own transcript renders as a same-page fragment,
  # so it reaches the Transcript panel below instead of opening a new tab.
  test "a link to this session's own transcript renders as a fragment link" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: Time.current,
      transcript_line_count: @session.transcript_line_count,
      summary: "CI went red — [see here](https://zimmer.example.com/sessions/#{@session.id}#message-1)."
    )

    get session_url(@session)

    assert_response :success
    assert_select "#session_#{@session.id}_status_panel div[data-controller='status-panel']" do
      assert_select "a[href='#message-1']"
    end
  end

  test "a stale summary shows the messages-since count alongside the cached text" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: 1.hour.ago,
      transcript_line_count: @session.transcript_line_count - 2,
      summary: "Working on it."
    )

    get session_url(@session)

    assert_response :success
    assert_match "Working on it.", response.body
    assert_match "2 messages since summary generated", response.body
  end

  # Rendering must never generate: the staleness count exists precisely so a
  # page view can show an out-of-date summary instead of paying for a fork.
  test "viewing a session with a stale summary enqueues nothing" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: 1.hour.ago,
      transcript_line_count: 0, summary: "Working on it."
    )

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      get session_url(@session)
    end
  end

  # The scope alone is not enough — the dashboard also receives cards over a
  # Turbo Stream, so this asserts the rendered page, not the query.
  test "the dashboard does not render a card for a summary fork" do
    fork = Session.create!(
      prompt: "summarize",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "Status summary for session ##{@session.id}",
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => @session.id }
    )

    get root_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@session)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(fork)}", 0
  end

  test "regenerate enqueues a forced generation" do
    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      post regenerate_status_summary_session_url(@session)
    end

    assert_redirected_to session_path(@session)
  end

  # --- The trash -------------------------------------------------------------

  # The bug this pair exists for: the button was enabled on an archived session,
  # the panel flipped to "Generating", and the job then declined in silence.
  test "an archived session with a clone still on disk regenerates like any other" do
    @session.update_column(:status, Session.statuses[:archived])

    get session_url(@session)

    assert_response :success
    assert_select "#session_#{@session.id}_status_panel button[disabled]", 0, "the button is live on an archived session"

    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      post regenerate_status_summary_session_url(@session)
    end
  end

  test "an archived session whose clone is gone says so instead of offering a dead button" do
    @session.update_column(:status, Session.statuses[:archived])
    FileUtils.remove_entry(@clone_path)

    get session_url(@session)

    assert_response :success
    assert_select "#session_#{@session.id}_status_panel button[disabled]"
    assert_match "deleted when it went to the trash", response.body
  end

  # A stale page can still POST at a button the render would now disable.
  test "regenerating a session whose clone is gone enqueues nothing and says why" do
    @session.update_column(:status, Session.statuses[:archived])
    FileUtils.remove_entry(@clone_path)

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      post regenerate_status_summary_session_url(@session)
    end

    assert_redirected_to session_path(@session)
    assert_match "deleted when it went to the trash", flash[:alert]
  end

  # The two non-clone structural refusals reach the same exits, so the surfaces
  # answer them the same way rather than only knowing about the trash.
  test "regenerating a session with no transcript is refused with its own reason" do
    @session.update_column(:transcript, nil)

    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      post regenerate_status_summary_session_url(@session)
    end

    assert_match "no transcript", flash[:alert]
  end

  test "the json refusal carries the reason and an unprocessable status" do
    @session.update_column(:status, Session.statuses[:archived])
    FileUtils.remove_entry(@clone_path)

    post regenerate_status_summary_session_url(@session), as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_match "deleted when it went to the trash", body["error"]
  end

  # The turbo_stream response is what the button actually gets, and it must not
  # come back saying "Generating" for work that was never queued.
  test "the turbo response to a refused regenerate does not claim to be generating" do
    @session.update_column(:status, Session.statuses[:archived])
    FileUtils.remove_entry(@clone_path)

    post regenerate_status_summary_session_url(@session), as: :turbo_stream

    assert_response :success
    assert_no_match(/Generating/, response.body)
    assert_match "deleted when it went to the trash", response.body
  end
end
