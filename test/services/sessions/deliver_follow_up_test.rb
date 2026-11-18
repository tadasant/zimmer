# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Sessions::DeliverFollowUp is the idle-session branch of the REST and MCP
# `follow_up` doors. What matters: it delivers through Session#deliver_follow_up!
# (the writer the web form shares), writes the goal and `prompt` column first,
# runs the caller's block before the job is enqueued, and rolls everything back
# when the delivery raises.
class Sessions::DeliverFollowUpTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "original",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }.merge(attrs))
  end

  test "delivers through Session#deliver_follow_up! with the source and attachments" do
    session = make_session
    source = TurnSource.new(surface: "api")
    job = stub(job_id: "job-1")
    session.expects(:deliver_follow_up!)
      .with("Do the thing", clear_metadata_keys: Session::STALE_RETRY_METADATA_KEYS,
            images: [ "/a.png" ], files: [ "/b.txt" ], source: source)
      .returns(job)

    result = Sessions::DeliverFollowUp.call(
      session: session, prompt: "Do the thing", goal: nil, source: source,
      images: [ "/a.png" ], files: [ "/b.txt" ]
    )

    assert_same job, result
  end

  test "writes the goal and prompt, stamps the tagged prompt and records the job" do
    session = make_session(goal: "old goal")
    job = stub(job_id: "job-2")
    AgentSessionJob.expects(:enqueue_with_prompt)
      .with(session.id, regexp_matches(/\ADo the thing/), images: nil, files: nil)
      .returns(job)

    Sessions::DeliverFollowUp.call(session: session, prompt: "Do the thing", goal: "new goal",
                                   source: TurnSource.new(surface: "api"))

    session.reload
    assert_equal "new goal", session.goal
    assert_equal "Do the thing", session.prompt
    assert_equal "job-2", session.running_job_id
    assert session.waiting?, "expected the turn queued for a worker, was #{session.status}"
    assert_match(/\ADo the thing/, session.metadata["pending_follow_up_prompt"])
    assert_equal "api", session.metadata.dig(Session::LAST_TURN_SOURCE_KEY, "surface")
  end

  # The web form clears Session::STALE_RETRY_METADATA_KEYS before it delivers.
  # A turn started over REST or MCP is the same event, so it starts from the
  # same clean slate: a fresh SIGTERM budget, no leftover failure reason, and no
  # dormancy record that would keep matching a sweep once the turn is over.
  test "drops the stale per-turn metadata the web form drops, and keeps the rest" do
    session = make_session(metadata: {
      "sigterm_retry_count" => 3,
      "last_sigterm_at" => 1.minute.ago.iso8601,
      "failure_reason" => "sigterm_retries_exhausted",
      "compact_retry_count" => 2,
      SpotSessionPause::PAUSED_REASON => "ceiling",
      "auth_outage_reason" => "pool_exhausted",
      Session::DELIBERATE_SLEEP_KEY => 1.hour.ago.iso8601,
      "api_error_last_checked_line" => 42
    })
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(stub(job_id: "job-stale"))

    Sessions::DeliverFollowUp.call(session: session, prompt: "Pick it back up", goal: nil,
                                   source: TurnSource.new(surface: "api"))

    metadata = session.reload.metadata
    %w[sigterm_retry_count last_sigterm_at failure_reason compact_retry_count auth_outage_reason].each do |key|
      assert_nil metadata[key], "expected #{key} cleared, was #{metadata[key].inspect}"
    end
    assert_nil metadata[SpotSessionPause::PAUSED_REASON]
    assert_nil metadata[Session::DELIBERATE_SLEEP_KEY]
    assert_equal 42, metadata["api_error_last_checked_line"],
      "the transcript scan position is not retry state and must survive"
    assert metadata["pending_follow_up_prompt"].present?
  end

  test "a blank goal leaves the session's goal alone" do
    session = make_session(goal: "keep me")
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(stub(job_id: "job-3"))

    Sessions::DeliverFollowUp.call(session: session, prompt: "Go", goal: nil, source: nil)

    assert_equal "keep me", session.reload.goal
  end

  test "runs the block before the job is enqueued" do
    session = make_session
    order = []
    AgentSessionJob.stubs(:enqueue_with_prompt).with { order << :enqueue }.returns(stub(job_id: "job-4"))

    Sessions::DeliverFollowUp.call(session: session, prompt: "Go", goal: nil, source: nil) { order << :block }

    assert_equal %i[block enqueue], order
  end

  test "a failed delivery rolls back the goal, the prompt and what the block wrote" do
    session = make_session(goal: "old goal")
    AgentSessionJob.stubs(:enqueue_with_prompt).raises(ActiveRecord::RecordInvalid.new(session))

    assert_raises(ActiveRecord::RecordInvalid) do
      Sessions::DeliverFollowUp.call(session: session, prompt: "Go", goal: "new goal", source: nil) do
        session.logs.create!(content: "written in the block", level: "info")
      end
    end

    session.reload
    assert_equal "old goal", session.goal
    assert_equal "original", session.prompt
    assert session.needs_input?
    assert_not session.logs.exists?(content: "written in the block")
  end
end
