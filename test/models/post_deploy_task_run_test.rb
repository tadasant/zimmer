# frozen_string_literal: true

require "test_helper"

class PostDeployTaskRunTest < ActiveSupport::TestCase
  Fake = Struct.new(:version, :task_name)

  def build_run(**attrs)
    PostDeployTaskRun.create!({ version: "20260101000000", name: "DoTheThing" }.merge(attrs))
  end

  test "ledger_for creates one row per version and returns the same row after" do
    task = Fake.new("20260101000001", "DoTheThing")

    first = PostDeployTaskRun.ledger_for(task)
    second = PostDeployTaskRun.ledger_for(task)

    assert_equal first.id, second.id
    assert_equal "DoTheThing", first.name
    assert_equal "pending", first.status
  end

  test "a claim is exclusive — the second caller gets nothing" do
    run = build_run
    other = PostDeployTaskRun.find(run.id)

    assert run.claim!(owner: "worker-a")
    assert_not other.claim!(owner: "worker-b")

    assert_equal "running", run.reload.status
    assert_equal "worker-a", run.locked_by
    assert_equal 1, run.attempts
  end

  test "a succeeded task can never be claimed again" do
    run = build_run
    run.claim!(owner: "worker-a")
    run.finish_success!

    assert_not run.due?
    assert_not PostDeployTaskRun.find(run.id).claim!(owner: "worker-b")
  end

  test "a failure backs off, and the retries eventually run out" do
    run = build_run
    delays = PostDeployTaskRun::RETRY_DELAYS

    delays.each_with_index do |delay, index|
      run.claim!(owner: "w")
      run.finish_failure!(RuntimeError.new("boom #{index}"))

      assert_equal "failed", run.status
      assert_equal index + 1, run.failures
      assert_in_delta (Time.current + delay).to_f, run.next_attempt_at.to_f, 5
      assert_not run.blocked?, "should still have retries left after #{index + 1} failures"
      assert_not run.due?, "should not be due before its backoff elapses"

      travel_to(run.next_attempt_at + 1.second) { assert run.due? }
    end

    travel_to(run.next_attempt_at + 1.second) do
      run.claim!(owner: "w")
      run.finish_failure!(RuntimeError.new("final"))
    end

    assert run.blocked?, "retries should be spent"
    assert_nil run.next_attempt_at
    assert_not run.due?
  end

  test "a task that yields for a slice keeps its progress and its retry budget" do
    run = build_run
    run.claim!(owner: "w")
    run.finish_failure!(RuntimeError.new("transient"))

    run.update!(next_attempt_at: 1.minute.ago)
    run.claim!(owner: "w")
    run.update!(cursor: { "sweep_last_id" => 42 })
    run.finish_continue!

    assert_equal "pending", run.status
    assert_equal 0, run.failures, "a slice that made progress is not a failure"
    assert_equal({ "sweep_last_id" => 42 }, run.reload.cursor)
    assert run.due?
  end

  test "an abandoned lease is reaped into an ordinary failure" do
    run = build_run
    run.claim!(owner: "dead-worker")
    run.update_columns(locked_at: (PostDeployTaskRun::LEASE + 1.minute).ago)

    PostDeployTaskRun.reap_expired_leases!

    run.reload
    assert_equal "failed", run.status
    assert_equal 1, run.failures
    assert_match(/stopped without finishing/, run.last_error)
    assert_match(/dead-worker/, run.last_error)
  end

  test "a live lease is left alone" do
    run = build_run
    run.claim!(owner: "busy-worker")

    PostDeployTaskRun.reap_expired_leases!

    assert_equal "running", run.reload.status
  end

  test "rearm clears the failure state but refuses to re-open a success" do
    failed = build_run
    failed.claim!(owner: "w")
    failed.finish_failure!(RuntimeError.new("boom"))
    failed.update!(next_attempt_at: nil)

    assert failed.rearm!
    assert_equal "pending", failed.status
    assert_equal 0, failed.failures
    assert failed.due?

    done = build_run(version: "20260101000002")
    done.claim!(owner: "w")
    done.finish_success!

    assert_not done.rearm!
    assert_equal "succeeded", done.reload.status
  end

  test "summary counts by state and escalates on a blocked task" do
    ok = build_run(version: "20260101000010", name: "Ok")
    ok.claim!(owner: "w")
    ok.finish_success!

    stuck = build_run(version: "20260101000011", name: "Stuck")
    stuck.claim!(owner: "w")
    stuck.finish_failure!(RuntimeError.new("boom"))
    stuck.update!(next_attempt_at: nil)

    registered = [ Fake.new("20260101000010", "Ok"), Fake.new("20260101000011", "Stuck"), Fake.new("20260101000012", "New") ]
    summary = PostDeployTaskRun.summary(registered: registered)

    assert_equal 2, summary[:total]
    assert_equal 1, summary[:succeeded]
    assert_equal 1, summary[:failed]
    assert_equal 1, summary[:blocked]
    assert_equal 1, summary[:awaiting_first_tick]
    assert_equal :critical, summary[:status].status
    assert_equal %w[20260101000010 20260101000011], summary[:tasks].map { |t| t[:version] }
  end

  test "summary warns rather than escalates while a failure still has retries" do
    run = build_run
    run.claim!(owner: "w")
    run.finish_failure!(RuntimeError.new("boom"))

    summary = PostDeployTaskRun.summary(registered: [ Fake.new(run.version, run.name) ])

    assert_equal :warning, summary[:status].status
    assert_equal 0, summary[:blocked]
  end

  test "summary is healthy and flags a row whose task file is gone" do
    run = build_run
    run.claim!(owner: "w")
    run.finish_success!

    summary = PostDeployTaskRun.summary(registered: [])

    assert_equal :healthy, summary[:status].status
    assert_equal false, summary[:tasks].first[:registered]
  end

  test "the error recorded is the class, the message and app frames only" do
    run = build_run
    run.claim!(owner: "w")

    error = begin
      raise ArgumentError, "not a widget"
    rescue ArgumentError => e
      e
    end

    run.finish_failure!(error)

    assert_match(/\AArgumentError: not a widget/, run.last_error)
    assert_operator run.last_error.length, :<=, 4000
    assert_not_nil run.last_error_at
  end
end
