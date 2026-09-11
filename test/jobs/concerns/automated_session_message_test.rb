require "test_helper"
require "mocha/minitest"

# The delivery half of tadasant/zimmer#1123, pinned end to end.
#
# `AutomatedSessionMessage` sends a poller's notice immediately only when the
# session is parked in `needs_input`; everything else is queued. That branch reads
# as "it waits behind the current turn", which is true mid-turn and says nothing at
# all about a session at REST in `waiting` — the state the `open-pr` skill's
# terminal step deliberately leaves a PR-holding session in so it does not occupy
# the human's action queue. Such a session has no next turn boundary of its own, so
# whether anything ever comes back for the row is not decided in that branch.
#
# It is decided by EnqueuedMessage's after_create_commit hook, which schedules
# EnqueuedMessageDrainJob for a session already idle by both resting states (#566).
# Nothing exercised that guarantee from the poller end, which is how #1123 came to
# be filed against a delivery path that already worked. This is that walk: a real
# conflict confirmed by the real evaluator, onto a real dormant session, all the way
# to a resumed turn.
class AutomatedSessionMessageTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  PR_URL = "https://github.com/owner/repo/pull/456".freeze

  test "a merge-conflict notice reaches a session at rest in waiting with no wake armed" do
    session = sessions(:waiting)
    session.update!(
      session_id: "runtime-abc",
      transcript: "work happened here",
      custom_metadata: { "github_pull_request_urls" => [ PR_URL ] }
    )

    # The precondition that makes this session unreachable by every other path: it
    # is resting, it has run, and nothing is scheduled to wake it.
    assert session.waiting?
    refute session.armed_one_time_wake?
    refute Sessions::LiveTurn.underway?(session)

    evaluator = Github::MergeConflictEvaluator.new
    evaluator.evaluate(session, refs, { PR_URL => conflicting_snapshot })
    travel (Github::MergeConflictEvaluator::MIN_CONFIRMATION_GAP_SECONDS + 1).seconds do
      session.reload
      evaluator.evaluate(session, refs, { PR_URL => conflicting_snapshot })

      session.reload
      assert session.enqueued_messages.pending.exists?, "the confirmed conflict is queued"

      # ...and something is scheduled to come back for it.
      assert_enqueued_with(job: EnqueuedMessageDrainJob, args: [ session.id ])

      stub_gh_conflicting
      perform_enqueued_jobs(only: EnqueuedMessageDrainJob)

      session.reload
      refute session.enqueued_messages.pending.exists?,
        "the notice must be delivered, not left pending on a session nothing will wake"
      assert_enqueued_with(job: AgentSessionJob)
    end
  end

  private

  def refs
    [ Github::PrRef.parse(PR_URL) ]
  end

  def conflicting_snapshot
    Github::PrSnapshot.new(
      ref: Github::PrRef.parse(PR_URL), state: "OPEN", merged_at: nil, mergeable: "CONFLICTING"
    )
  end

  # The drain re-reads the PR before delivering, so the notice is only still worth
  # sending if GitHub still says CONFLICTING (EnqueuedMessage#stale?).
  def stub_gh_conflicting
    status = mock("status")
    status.stubs(:success?).returns(true)
    status.stubs(:exitstatus).returns(0)
    BoundedSubprocess.stubs(:run).returns([ "", "", status ])
    BoundedSubprocess.stubs(:run)
      .with { |*args| args.first[1] == "pr" && args.first[2] == "view" }
      .returns([ { "state" => "OPEN", "mergedAt" => nil, "mergeable" => "CONFLICTING" }.to_json, "", status ])
  end
end
