# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The fork-backed generation path for the Status panel's blurb, and the caching
# rule that decides when it may run at all.
class SessionStatusSummaryGeneratorTest < ActiveSupport::TestCase
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @transcript = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Ship the thing" }, "timestamp" => "2026-08-01T10:00:00Z" },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "Opened the PR" } ] }, "timestamp" => "2026-08-01T10:00:01Z" }
    ].map { |line| JSON.generate(line) }.join("\n") + "\n"

    @fs = MockFileSystemAdapter.new
    @clone_path = "/home/test/.zimmer/clones/test-repo-main-1-abcd"
    @fs.mkdir_p(@clone_path)

    @session = Session.create!(
      prompt: "Ship the thing",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      transcript: @transcript,
      goal: "Open a PR and label it ready to merge",
      title: "Ship the thing",
      metadata: { "clone_path" => @clone_path, "working_directory" => @clone_path }
    )
  end

  teardown do
    Mocha::Mockery.instance.teardown
  end

  def generate(**opts)
    SessionStatusSummaryGenerator.call(session: @session, file_system: @fs, **opts)
  end

  # --- The fork-backed path -------------------------------------------------

  test "generation forks the session at its last transcript message and prompts the fork" do
    result = nil
    assert_difference -> { Session.count }, 1 do
      result = generate
    end

    assert_equal :started, result.outcome
    fork = result.fork_session

    assert_equal @session.id, fork.metadata[SessionStatusSummaryGenerator::FORK_MARKER]
    assert_equal 1, fork.metadata["forked_at_message_index"], "forks at the last line (2 lines, 0-indexed)"
    assert_equal @transcript, fork.transcript, "the fork carries the whole conversation up to the fork point"
  end

  # A fork inherits the source's goal, and a goal is an instruction to act. A
  # summarizer carrying "open a PR and label it ready to merge" would go do that.
  test "the summary fork does not inherit the source session's goal" do
    fork = generate.fork_session

    assert_nil fork.goal
    assert_equal "Status summary for session ##{@session.id}", fork.title
    assert_not fork.heartbeat_enabled
  end

  test "the fork is sent exactly one follow-up prompt asking for the summary" do
    prompts = []
    Session.any_instance.stubs(:deliver_follow_up!).with do |prompt, *|
      prompts << prompt
      true
    end

    generate

    assert_equal 1, prompts.size
    assert_match(/2-3 sentences/, prompts.first)
    assert_match(%r{#message-INDEX}, prompts.first)
    assert_match(/Do not run any tools/, prompts.first)
  end

  test "a started generation is recorded as pending against the fork and the line count" do
    fork = generate.fork_session
    record = @session.reload.status_summary

    assert_equal "pending", record.state
    assert record.pending?
    assert_equal fork.id, record.fork_session_id
    assert_equal 2, record.requested_line_count
    assert_equal 0, record.transcript_line_count, "not advanced until a summary actually lands"
  end

  # --- Caching / staleness --------------------------------------------------

  test "a current summary is not regenerated" do
    SessionStatusSummary.create!(
      session: @session, summary: "All good.", state: "ready",
      transcript_line_count: @session.transcript_line_count, generated_at: Time.current
    )

    assert_no_difference -> { Session.count } do
      assert_equal :fresh, generate.outcome
    end
  end

  test "a summary regenerates once the transcript has moved" do
    SessionStatusSummary.create!(
      session: @session, summary: "All good.", state: "ready",
      transcript_line_count: @session.transcript_line_count - 1, generated_at: Time.current
    )

    assert_equal :started, generate.outcome
  end

  test "force regenerates a summary Zimmer considers current" do
    SessionStatusSummary.create!(
      session: @session, summary: "All good.", state: "ready",
      transcript_line_count: @session.transcript_line_count, generated_at: Time.current
    )

    assert_equal :started, generate(force: true).outcome
  end

  test "a generation already in flight is not started twice, even when forced" do
    generate

    assert_no_difference -> { Session.count } do
      assert_equal :pending, generate(force: true).outcome
    end
  end

  test "an abandoned generation does not block a new one" do
    generate
    @session.reload.status_summary.update!(requested_at: (SessionStatusSummary::PENDING_TIMEOUT + 1.minute).ago)

    assert_equal :started, generate(force: true).outcome
  end

  # --- Refusals -------------------------------------------------------------

  test "a status-summary fork never summarizes itself" do
    fork = generate.fork_session

    result = SessionStatusSummaryGenerator.call(session: fork, file_system: @fs)

    assert_equal :skipped, result.outcome
  end

  test "a session with no transcript is skipped" do
    @session.update_column(:transcript, nil)

    assert_equal :skipped, generate.outcome
  end

  test "an archived session is skipped" do
    @session.update_column(:status, Session.statuses[:archived])

    assert_equal :skipped, generate.outcome
  end

  test "a fork failure is recorded on the summary rather than raised" do
    failing = Class.new do
      def self.call(**)
        ForkSessionService::Result.new(success?: false, error: "Source clone directory does not exist")
      end
    end

    result = SessionStatusSummaryGenerator.call(session: @session, fork_service: failing)

    assert_equal :failed, result.outcome
    record = @session.reload.status_summary
    assert_equal "failed", record.state
    assert_equal "Source clone directory does not exist", record.error
  end
end
