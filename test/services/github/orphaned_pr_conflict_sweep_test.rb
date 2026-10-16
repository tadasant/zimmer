require "test_helper"
require "mocha/minitest"

class Github::OrphanedPrConflictSweepTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/owner/repo/pull/456".freeze
  CONFIRMED = Github::MergeConflictEvaluator::CONFIRMED_METADATA_KEY
  SUSPECTED = Github::MergeConflictEvaluator::SUSPECTED_METADATA_KEY
  REVIVALS = Github::OrphanedPrConflictSweep::REVIVALS_METADATA_KEY

  setup do
    @session = sessions(:with_pr_url_and_status)
    # No test here reaches GitHub. The REST re-read answers "could not ask", which
    # leaves each snapshot as the stubbed PrSnapshot.fetch built it.
    Github::PrSnapshot.stubs(:fetch_rest_mergeable).returns(nil)
    # The cutover is a fixed date; move it behind every session these tests end.
    Github::OrphanedPrConflictSweep.stubs(:watched_since).returns(30.days.ago)
  end

  # ---- who is watched ----

  test "candidates are archived or failed producers that ended inside the window" do
    archived = end_session(@session, :archived, ended: 2.days.ago)
    stale = end_session(sessions(:with_multiple_pr_urls), :archived, ended: 8.days.ago)

    ids = Github::OrphanedPrConflictSweep.candidates.pluck(:id)

    assert_includes ids, archived.id
    refute_includes ids, stale.id
    assert Github::OrphanedPrConflictSweep.watched?(archived)
  end

  test "a producer that ended before the cutover is never watched" do
    Github::OrphanedPrConflictSweep.stubs(:watched_since).returns(1.day.ago)
    archived = end_session(@session, :archived, ended: 2.days.ago)

    refute_includes Github::OrphanedPrConflictSweep.candidates.pluck(:id), archived.id
    refute Github::OrphanedPrConflictSweep.watched?(archived)
  end

  test "a failed producer is watched by its last human activity, which the sweep never moves" do
    failed = end_session(@session, :failed, ended: 2.days.ago)
    assert Github::OrphanedPrConflictSweep.watched?(failed)

    failed.update!(metadata: failed.metadata.merge("last_user_activity_at" => 8.days.ago.iso8601))
    refute Github::OrphanedPrConflictSweep.watched?(failed.reload)

    # Nothing is read for it, though updated_at keeps it in the loose SQL bound.
    Github::PrSnapshot.expects(:fetch).never
    sweep
  end

  # The SQL never casts the stamp: a value shaped like a timestamp but not one
  # would raise there, and take the sweep down for every session.
  test "a malformed activity stamp cannot break the query" do
    failed = end_session(@session, :failed, ended: 2.days.ago)
    failed.update!(metadata: failed.metadata.merge("last_user_activity_at" => "2026-13-45T00:00:00Z"))

    assert_nothing_raised { Github::OrphanedPrConflictSweep.candidates.pluck(:id) }
  end

  test "live sessions are not candidates: the poll pass covers them" do
    @session.update!(status: :needs_input)

    refute_includes Github::OrphanedPrConflictSweep.candidates.pluck(:id), @session.id
  end

  # ---- the debounce, unchanged ----

  test "the first conflicting reading only suspects, and brings nobody back" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:conflicting)
    UnarchiveSessionService.expects(:call).never

    sweep

    @session.reload
    assert_equal [ PR_URL ], @session.custom_metadata[SUSPECTED].keys
    assert_nil @session.custom_metadata[CONFIRMED]
    assert @session.archived?
  end

  test "a transient conflicting reading never brings the producer back" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:conflicting)
    sweep

    reading(:clean)
    UnarchiveSessionService.expects(:call).never
    sweep_later

    @session.reload
    assert_equal({}, @session.custom_metadata[SUSPECTED])
    assert @session.archived?
  end

  # ---- the revival ----

  test "a confirmed conflict unarchives the producer and tells it, saying why it is back" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:conflicting, head_sha: "abc123")
    sweep

    expect_unarchive
    Session.any_instance.expects(:deliver_follow_up!).once.with do |prompt, **|
      prompt.start_with?(AutomatedPrompts.merge_conflict_message(PR_URL)) &&
        prompt.include?("brought this session back from `archived`") &&
        AutomatedPrompts.merge_conflict_pr_url(prompt) == PR_URL
    end
    sweep_later

    @session.reload
    assert_equal({ PR_URL => "abc123" }, @session.custom_metadata[CONFIRMED])
    assert_equal({ PR_URL => 1 }, @session.custom_metadata[REVIVALS])
    assert @session.logs.where("content LIKE ?", "%Merge conflict detected on #{PR_URL} while this session was archived%").exists?
  end

  test "a confirmed conflict resumes a failed producer directly" do
    end_session(@session, :failed, ended: 1.day.ago)
    reading(:conflicting)
    sweep

    UnarchiveSessionService.expects(:call).never
    Session.any_instance.expects(:deliver_follow_up!).once.with do |prompt, **|
      prompt.include?("brought this session back from `failed`")
    end
    sweep_later

    @session.reload
    assert_equal({ PR_URL => 1 }, @session.custom_metadata[REVIVALS])
    assert @session.logs.where("content LIKE ?", "%while this session was failed — resumed to deliver it%").exists?
  end

  test "a producer is brought back once per conflict episode, not on every sweep" do
    end_session(@session, :archived, ended: 1.day.ago,
                extra: { CONFIRMED => { PR_URL => "abc123" } })
    reading(:conflicting, head_sha: "abc123")
    UnarchiveSessionService.expects(:call).never

    sweep
    sweep_later

    assert_equal({ PR_URL => "abc123" }, @session.reload.custom_metadata[CONFIRMED])
  end

  test "a replaced producer is not brought back" do
    end_session(@session, :archived, ended: 1.day.ago)
    sessions(:running).update!(custom_metadata: { Session::REPLACES_SESSION_KEY => @session.id.to_s })
    reading(:conflicting)
    sweep

    UnarchiveSessionService.expects(:call).never
    sweep_later

    # Recorded as handled, so it is not retried on every sweep.
    assert_equal [ PR_URL ], @session.reload.custom_metadata[CONFIRMED].keys
    assert_nil @session.custom_metadata[REVIVALS]
  end

  test "this run's revival budget defers the rest, leaving the suspicion standing" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:conflicting)
    sweep

    UnarchiveSessionService.expects(:call).never
    travel (Github::PrPollPass::MERGE_CONFLICT_INTERVAL_SECONDS + 1).seconds
    spent = Github::OrphanedPrConflictSweep.new
    spent.instance_variable_set(:@revivals_this_run, Github::OrphanedPrConflictSweep::MAX_REVIVALS_PER_RUN)
    spent.sweep_session(@session.reload)

    @session.reload
    assert @session.archived?
    assert_equal [ PR_URL ], @session.custom_metadata[SUSPECTED].keys
    assert_nil @session.custom_metadata[CONFIRMED]
    assert_nil @session.custom_metadata[REVIVALS]
  end

  # The second PR's conflict is confirmed after the first one's revival has made
  # the session live: it is told through the ordinary path, once, and both PRs
  # are recorded as notified so the live pass does not tell it again.
  test "two conflicting PRs bring the producer back once and tell it about both" do
    other = "https://github.com/owner/repo/pull/457"
    end_session(@session, :archived, ended: 1.day.ago, extra: {
      "github_pull_request_urls" => [ PR_URL, other ],
      "github_pull_request_statuses" => { PR_URL => "open", other => "open" }
    })
    Github::PrSnapshot.stubs(:fetch).with { |ref| ref.url == PR_URL }.returns(snapshot(:conflicting, head_sha: "a" * 40))
    Github::PrSnapshot.stubs(:fetch).with { |ref| ref.url == other }
      .returns(Github::PrSnapshot.new(ref: Github::PrRef.parse(other), state: "OPEN", merged_at: nil,
                                      mergeable: "CONFLICTING", head_sha: "b" * 40))
    sweep

    expect_unarchive
    prompts = []
    Session.any_instance.expects(:deliver_follow_up!).twice.with { |prompt, **| prompts << prompt }
    sweep_later

    assert_equal 1, prompts.count { |p| p.include?("brought this session back") }
    assert_equal [ PR_URL, other ].sort, prompts.map { |p| AutomatedPrompts.merge_conflict_pr_url(p) }.sort
    assert_equal({ PR_URL => "a" * 40, other => "b" * 40 }, @session.reload.custom_metadata[CONFIRMED])
  end

  test "a newer session tracking the same PR is the owner, not this one" do
    end_session(@session, :archived, ended: 1.day.ago)
    newer = Session.create!(
      agent_runtime: "claude_code", status: :needs_input, prompt: "picked the PR up",
      git_root: "https://github.com/owner/repo.git", branch: "main",
      custom_metadata: { "github_pull_request_urls" => [ PR_URL ] }
    )
    assert_operator newer.id, :>, @session.id
    reading(:conflicting)
    sweep

    UnarchiveSessionService.expects(:call).never
    sweep_later

    assert_equal [ PR_URL ], @session.reload.custom_metadata[CONFIRMED].keys
    assert_nil @session.custom_metadata[REVIVALS]
  end

  test "a producer with no runtime session id is not brought back" do
    end_session(@session, :archived, ended: 1.day.ago)
    @session.update!(session_id: nil)
    reading(:conflicting)
    sweep

    UnarchiveSessionService.expects(:call).never
    sweep_later

    assert_nil @session.reload.custom_metadata[REVIVALS]
  end

  test "a PR at its revival cap is not read at all" do
    end_session(@session, :archived, ended: 1.day.ago,
                extra: { REVIVALS => { PR_URL => Github::OrphanedPrConflictSweep::MAX_REVIVALS_PER_PR } })
    Github::PrSnapshot.expects(:fetch).never

    sweep
  end

  test "an unarchive that fails leaves the suspicion standing, counts the attempt, and still stamps the poll" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:conflicting)
    sweep

    UnarchiveSessionService.expects(:call).once.returns(
      UnarchiveSessionService::Result.new(success?: false, error: "clone failed")
    )
    sweep_later

    @session.reload
    assert @session.archived?
    assert_equal [ PR_URL ], @session.custom_metadata[SUSPECTED].keys
    assert_empty @session.custom_metadata[CONFIRMED].to_h, "the marker set before the revival is taken back"
    assert_equal({ PR_URL => 1 }, @session.custom_metadata[REVIVALS])
    assert_in_delta Time.current,
      Time.zone.parse(@session.custom_metadata.dig("poller_last_polled_at", Github::OrphanedPrConflictSweep::POLL_BACKOFF_KEY)),
      5.seconds
  end

  # ---- leaving the population ----

  test "a merged reading is recorded, so the PR is never read again" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:clean, state: "MERGED")
    sweep

    assert_equal "merged", @session.reload.custom_metadata.dig("github_pull_request_statuses", PR_URL)

    Github::PrSnapshot.expects(:fetch).never
    sweep_later(Github::OrphanedPrConflictSweep::POLL_INTERVAL)
  end

  # ---- cadence ----

  test "a producer with nothing suspected is read every POLL_INTERVAL, not every tick" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:clean)
    sweep

    Github::PrSnapshot.expects(:fetch).never
    sweep_later
  end

  test "a fresh suspicion is re-read on the debounce's cadence" do
    end_session(@session, :archived, ended: 1.day.ago)
    reading(:conflicting)
    sweep

    Github::PrSnapshot.expects(:fetch).once.returns(snapshot(:clean))
    sweep_later
  end

  private

  def end_session(session, status, ended:, extra: {})
    session.update!(
      status: status,
      session_id: session.session_id.presence || "runtime-#{session.id}",
      archived_at: status == :archived ? ended : nil,
      metadata: (session.metadata || {}).merge("last_user_activity_at" => ended.iso8601),
      custom_metadata: (session.custom_metadata || {}).merge(extra)
    )
    session
  end

  def reading(kind, state: "OPEN", head_sha: nil)
    Github::PrSnapshot.stubs(:fetch).returns(snapshot(kind, state: state, head_sha: head_sha))
  end

  def snapshot(kind, state: "OPEN", head_sha: nil)
    Github::PrSnapshot.new(
      ref: Github::PrRef.parse(PR_URL),
      state: state,
      merged_at: state == "MERGED" ? "2025-01-01T12:00:00Z" : nil,
      mergeable: kind == :conflicting ? "CONFLICTING" : "MERGEABLE",
      head_sha: head_sha
    )
  end

  # Only this test's session, so `.never` and `.once` are about it.
  def sweep
    Github::OrphanedPrConflictSweep.stubs(:candidates).returns(Session.where(id: @session.id))
    Github::OrphanedPrConflictSweep.new.run
    @session.reload
  end

  # A later sweep, one debounce gap on: due again for a suspicion, not otherwise.
  def sweep_later(gap = Github::PrPollPass::MERGE_CONFLICT_INTERVAL_SECONDS + 1)
    travel gap.seconds
    sweep
  end

  # UnarchiveSessionService re-clones; here it only does what the sweep relies on
  # it for, returning the session to needs_input.
  def expect_unarchive
    UnarchiveSessionService.expects(:call).once.with do |session:, **|
      session.update!(status: :needs_input, archived_at: nil)
      true
    end.returns(UnarchiveSessionService::Result.new(success?: true, session: @session))
  end
end
