# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The MCP half of the Status panel: an agent must be able to read a session's
# blurb (get_session) and ask for it to be rewritten (action_session), and must
# not see Zimmer's throwaway summary forks in a session listing.
class Mcp::Tools::StatusSummaryParityTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @context = Mcp::Context.new(tool_groups: "sessions")
    # A real directory: regeneration is refused when there is no clone left to
    # fork — see SessionStatusSummaryGenerator.unavailable_reason.
    @clone_path = Dir.mktmpdir("status-summary-clone")

    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "Ship the thing",
      metadata: { "clone_path" => @clone_path },
      transcript: "{}\n{}\n{}\n{}\n"
    )
  end

  teardown do
    FileUtils.remove_entry(@clone_path) if @clone_path && File.directory?(@clone_path)
    Mocha::Mockery.instance.teardown
  end

  # --- get_session ----------------------------------------------------------

  test "get_session reports a current summary with its freshness" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: Time.current,
      transcript_line_count: 4, summary: "The PR is open and CI is green."
    )

    output = Mcp::Tools::GetSession.new(context: @context).call("id" => @session.id)

    assert_includes output, "### Status Summary"
    assert_includes output, "The PR is open and CI is green."
    assert_includes output, "**Freshness:** current"
  end

  # #988: "current — no transcript events since it was written" was rendered
  # identically for a session that answered thirty seconds ago and for four
  # production sessions that had been dead for between 36 minutes and three hours.
  # Zero events is still zero events; the duration next to it is what separates
  # quiet from silent.
  test "get_session says how long a current summary has been current" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: 3.minutes.ago,
      transcript_line_count: 4, summary: "The PR is open and CI is green."
    )

    output = Mcp::Tools::GetSession.new(context: @context).call("id" => @session.id)

    assert_includes output, "no transcript event has landed in the 3 minutes since it was written"
    assert_not_includes output, "Zimmer's own orphan sweep",
      "a session at rest is not silent — it is finished, and must not be flagged"
  end

  test "get_session flags a running session that has been silent past the orphan sweep's threshold" do
    @session.update!(status: :running)
    generated_at = (CleanupOrphanedSessionsJob::INACTIVITY_THRESHOLD + 77.minutes).ago
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: generated_at,
      transcript_line_count: 4, summary: "Waiting on the test run."
    )

    output = Mcp::Tools::GetSession.new(context: @context).call("id" => @session.id)

    assert_includes output, "This session has been `running` and silent for that whole window"
    assert_includes output, "silent since #{generated_at.utc.iso8601}"
    assert_includes output, "A slow turn looks identical from here",
      "the line must not assert the session is dead — a long tool call reads the same way"
  end

  test "get_session marks a stale summary stale and counts how far behind it is" do
    SessionStatusSummary.create!(
      session: @session, state: "ready", generated_at: 1.hour.ago,
      transcript_line_count: 1, summary: "Working on it."
    )

    output = Mcp::Tools::GetSession.new(context: @context).call("id" => @session.id)

    assert_includes output, "**Freshness:** STALE — 3 transcript event(s) since it was written"
  end

  # A failed generation leaves the last real summary in place, so the blurb alone
  # does not say why it is the one still showing. The web panel and
  # `GET /api/v1/sessions/:id` both carry the reason; this is the MCP half.
  test "get_session gives the reason a stale summary is still the one showing" do
    SessionStatusSummary.create!(
      session: @session, state: "failed", generated_at: 1.hour.ago,
      transcript_line_count: 1, summary: "Working on it.",
      error: "The summary fork was parked before it could answer (quota_exhausted). It will be retried."
    )

    output = Mcp::Tools::GetSession.new(context: @context).call("id" => @session.id)

    assert_includes output, "**Freshness:** STALE"
    assert_includes output, "**Last regeneration failed:** The summary fork was parked"
  end

  test "get_session says plainly when no summary exists rather than omitting the section" do
    output = Mcp::Tools::GetSession.new(context: @context).call("id" => @session.id)

    assert_includes output, "### Status Summary"
    assert_includes output, "_No summary has been generated for this session yet._"
  end

  # Reading must never generate — the same rule the session page follows.
  test "get_session does not enqueue a generation" do
    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      Mcp::Tools::GetSession.new(context: @context).call("id" => @session.id)
    end
  end

  # --- action_session -------------------------------------------------------

  test "action_session exposes regenerate_status_summary and enqueues a forced generation" do
    assert_includes Mcp::Tools::ActionSession::ACTIONS, "regenerate_status_summary"

    result = nil
    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      result = Mcp::Tools::ActionSession.new(context: @context)
        .call("action" => "regenerate_status_summary", "session_id" => @session.id)
    end

    assert_includes result, "## Status Summary Regenerating"
  end

  # Parity with the panel's button and the REST endpoint: archived is not a
  # reason to refuse, a reclaimed clone is — and an agent gets told which.
  test "action_session regenerates an archived session that still has its clone" do
    @session.update_column(:status, Session.statuses[:archived])

    result = nil
    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      result = Mcp::Tools::ActionSession.new(context: @context)
        .call("action" => "regenerate_status_summary", "session_id" => @session.id)
    end

    assert_includes result, "## Status Summary Regenerating"
  end

  test "action_session regenerates an archived session whose clone is gone" do
    @session.update_column(:status, Session.statuses[:archived])
    FileUtils.remove_entry(@clone_path)

    result = nil
    assert_enqueued_with(job: SessionStatusSummaryJob, args: [ @session.id, { force: true } ]) do
      result = Mcp::Tools::ActionSession.new(context: @context)
        .call("action" => "regenerate_status_summary", "session_id" => @session.id)
    end

    assert_includes result, "## Status Summary Regenerating"
  end

  test "action_session errors with the reason when the session has nothing to summarize" do
    @session.update_column(:transcript, nil)

    error = nil
    assert_no_enqueued_jobs(only: SessionStatusSummaryJob) do
      error = assert_raises(Mcp::ToolError) do
        Mcp::Tools::ActionSession.new(context: @context)
          .call("action" => "regenerate_status_summary", "session_id" => @session.id)
      end
    end

    assert_match(/no conversation/, error.message)
  end

  # The tool's prose is the only thing an agent reads before choosing the
  # action, so it has to carry the same rule the behaviour does.
  test "the tool description says an archived session is a candidate however long ago" do
    description = Mcp::Tools::ActionSession.description_value

    assert_match(/archived session is a normal candidate, however long ago/, description)
    assert_no_match(/ten seconds after it is archived/, description)
  end

  test "the tool description documents the new action" do
    assert_match(/regenerate_status_summary/, Mcp::Tools::ActionSession.description_value)
  end

  # A session driving itself gets the self-management subset only; regenerating
  # a summary forks another session's conversation, so it stays out.
  test "the self-session tool does not expose regenerate_status_summary" do
    assert_not_includes Mcp::Tools::SelfSessionActionSession::ACTIONS, "regenerate_status_summary"
  end

  # --- quick_search_sessions ------------------------------------------------

  test "summary forks do not appear in a session search" do
    fork = Session.create!(
      prompt: "summarize",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "Status summary for session ##{@session.id}",
      metadata: { SessionStatusSummaryGenerator::FORK_MARKER => @session.id }
    )

    output = Mcp::Tools::QuickSearchSessions.new(context: @context).call({})

    assert_includes output, "(ID: #{@session.id})"
    assert_not_includes output, "(ID: #{fork.id})"
  end
end
