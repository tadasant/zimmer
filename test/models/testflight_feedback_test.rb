# frozen_string_literal: true

require "test_helper"

class TestflightFeedbackTest < ActiveSupport::TestCase
  test "the headline is the crash report's exception, termination and crashed-thread lines" do
    feedback = TestflightFeedback.new(kind: "crash", crash_log: AppStoreConnectFixtures::CRASH_LOG)

    assert_equal "Exception Type:  EXC_CRASH (SIGABRT) · Exception Codes: 0x0000000000000000, 0x0000000000000000 · " \
                 "Termination Reason: SIGNAL 6 Abort trap: 6 · Crashed Thread:  0", feedback.headline
    assert_nil TestflightFeedback.new(kind: "crash").headline
    assert_nil TestflightFeedback.new(kind: "crash", crash_log: "not an Apple crash report").headline
  end

  test "the headline is read from an .ips report too" do
    ips = { app_name: "Zimmer", bug_type: "309" }.to_json + "\n" +
      { exception: { type: "EXC_BAD_ACCESS", signal: "SIGSEGV" }, termination: { namespace: "SIGNAL", indicator: "Segmentation fault: 11" }, faultingThread: 3 }.to_json

    assert_equal "Exception Type: EXC_BAD_ACCESS SIGSEGV · Termination Reason: SIGNAL Segmentation fault: 11 · Crashed Thread: 3",
      TestflightFeedback.new(kind: "crash", crash_log: ips).headline
  end

  test "asc_id is unique, so a submission is stored once" do
    TestflightFeedback.create!(asc_id: "dup", kind: "crash")

    refute_predicate TestflightFeedback.new(asc_id: "dup", kind: "crash"), :valid?
    assert_raises(ActiveRecord::RecordNotUnique) { TestflightFeedback.new(asc_id: "dup", kind: "crash").save!(validate: false) }
  end

  test "awaiting_crash_log is recent crashes without a log" do
    waiting = TestflightFeedback.create!(asc_id: "w", kind: "crash")
    TestflightFeedback.create!(asc_id: "done", kind: "crash", crash_log: "x")
    TestflightFeedback.create!(asc_id: "shot", kind: "screenshot")
    TestflightFeedback.create!(asc_id: "stale", kind: "crash", created_at: 8.days.ago)

    assert_equal [ waiting ], TestflightFeedback.awaiting_crash_log(since: 7.days.ago).to_a
  end
end
