require "test_helper"
require "mocha/minitest"

class Github::PrStatusEvaluatorTest < ActiveSupport::TestCase
  setup do
    @session_with_pr = sessions(:with_pr_url)
  end

  MERGED_PR_URL = "https://github.com/owner/repo/pull/123".freeze

  # A poll cycle spans several seconds of GitHub API calls, so the session object this
  # evaluator holds is stale by the time it writes. Before the write became a single-statement
  # jsonb merge, that write rebuilt the whole column from the stale snapshot — erasing a
  # PR URL the session's own transcript hook recorded during the poll, which is a session
  # where none of the GitHub integration ever engages again (issue #70).
  test "evaluate keeps a PR url a transcript hook recorded during the poll" do
    first_pr = "https://github.com/owner/repo/pull/123"
    second_pr = "https://github.com/owner/repo/pull/456"
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ first_pr ] })

    stale_view = Session.find(@session_with_pr.id)

    # Mid-poll, the agent opens a second PR and the transcript hook records it.
    TranscriptHooks::BaseHook
      .new(session: Session.find(@session_with_pr.id), transcript_content: "", new_messages: [])
      .send(:update_custom_metadata, "github_pull_request_urls" => [ first_pr, second_pr ])

    evaluate(stale_view, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal [ first_pr, second_pr ], @session_with_pr.custom_metadata["github_pull_request_urls"],
      "the poller must not erase a PR url recorded while it was polling"
    assert_equal({ first_pr => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
  end

  test "evaluate updates statuses when they change" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ MERGED_PR_URL ] })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
  end

  test "evaluate does not update when statuses are unchanged" do
    # nil CI status means no change (delete from empty hash = still empty), and the PR
    # status is already "open", so nothing should change.
    @session_with_pr.update!(
      custom_metadata: {
        "github_pull_request_urls" => [ MERGED_PR_URL ],
        "github_pull_request_statuses" => { MERGED_PR_URL => "open" },
        "github_pull_request_ci_statuses" => {}
      }
    )

    original_updated_at = @session_with_pr.updated_at

    evaluate(@session_with_pr, "open", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal original_updated_at, @session_with_pr.updated_at
  end

  test "evaluate leaves the recorded status alone when the PR could not be read" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ MERGED_PR_URL ] })

    # nil is the snapshot the pass hands over when its `gh pr view` did not complete.
    evaluate(@session_with_pr, nil, evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_nil @session_with_pr.custom_metadata["github_pull_request_statuses"]
  end

  test "evaluate updates all PR statuses" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [
        "https://github.com/owner/repo/pull/1",
        "https://github.com/owner/repo/pull/2"
      ]
    })

    evaluate(@session_with_pr, "open", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({
      "https://github.com/owner/repo/pull/1" => "open",
      "https://github.com/owner/repo/pull/2" => "open"
    }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
  end

  # ---- CI status ----

  test "evaluate fetches CI status for open PRs" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ MERGED_PR_URL ] })

    evaluate(@session_with_pr, "open", evaluator: PendingChecks.new)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "open" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({ MERGED_PR_URL => "pending" }, @session_with_pr.custom_metadata["github_pull_request_ci_statuses"])
  end

  test "evaluate clears CI status for merged PRs" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" },
      "github_pull_request_ci_statuses" => { MERGED_PR_URL => "pending" }
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_ci_statuses"])
  end

  test "evaluate does not update when statuses and ci statuses are unchanged" do
    @session_with_pr.update!(
      custom_metadata: {
        "github_pull_request_urls" => [ MERGED_PR_URL ],
        "github_pull_request_statuses" => { MERGED_PR_URL => "open" },
        "github_pull_request_ci_statuses" => { MERGED_PR_URL => "pass" }
      }
    )

    original_updated_at = @session_with_pr.updated_at

    evaluate(@session_with_pr, "open", evaluator: PassingChecks.new)

    @session_with_pr.reload
    assert_equal original_updated_at, @session_with_pr.updated_at
  end

  test "fetch_ci_status determines overall status from multiple checks" do
    evaluator = Github::PrStatusEvaluator.new

    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    all_pass = [ { "bucket" => "pass" }, { "bucket" => "pass" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ all_pass, "", success_status ])
    assert_equal "pass", evaluator.send(:fetch_ci_status, ref)

    one_fail = [ { "bucket" => "pass" }, { "bucket" => "fail" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ one_fail, "", success_status ])
    assert_equal "fail", evaluator.send(:fetch_ci_status, ref)

    one_pending = [ { "bucket" => "pass" }, { "bucket" => "pending" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ one_pending, "", success_status ])
    assert_equal "pending", evaluator.send(:fetch_ci_status, ref)

    fail_and_pending = [ { "bucket" => "fail" }, { "bucket" => "pending" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ fail_and_pending, "", success_status ])
    assert_equal "fail", evaluator.send(:fetch_ci_status, ref)
  end

  test "fetch_ci_status returns nil for empty checks array" do
    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    # GitHub answered and the PR has no checks. nil, not CI_STATUS_UNKNOWN: this is a
    # real reading, so the caller clears any recorded CI status.
    BoundedSubprocess.stubs(:run).returns([ "[]", "", success_status ])
    assert_nil Github::PrStatusEvaluator.new.send(:fetch_ci_status, ref)
  end

  test "fetch_ci_status handles exit code 8 for pending checks" do
    pending_status = mock
    pending_status.stubs(:success?).returns(false)
    pending_status.stubs(:exitstatus).returns(8)

    BoundedSubprocess.stubs(:run).returns([ [ { "bucket" => "pending" } ].to_json, "", pending_status ])
    assert_equal "pending", Github::PrStatusEvaluator.new.send(:fetch_ci_status, ref)
  end

  test "fetch_ci_status reports a command failure as unknown, not as an absence of checks" do
    fail_status = mock
    fail_status.stubs(:success?).returns(false)
    fail_status.stubs(:exitstatus).returns(1)

    BoundedSubprocess.stubs(:run).returns([ "", "Error", fail_status ])
    assert_equal Github::PrStatusEvaluator::CI_STATUS_UNKNOWN,
                 Github::PrStatusEvaluator.new.send(:fetch_ci_status, ref)
  end

  test "fetch_ci_status handles skipping status" do
    evaluator = Github::PrStatusEvaluator.new

    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    all_skipping = [ { "bucket" => "skipping" }, { "bucket" => "skipping" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ all_skipping, "", success_status ])
    assert_equal "skipping", evaluator.send(:fetch_ci_status, ref)

    skipping_and_pass = [ { "bucket" => "skipping" }, { "bucket" => "pass" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ skipping_and_pass, "", success_status ])
    assert_equal "pass", evaluator.send(:fetch_ci_status, ref)
  end

  test "fetch_ci_status handles cancel status with correct priority" do
    evaluator = Github::PrStatusEvaluator.new

    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    cancel_and_pass = [ { "bucket" => "cancel" }, { "bucket" => "pass" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ cancel_and_pass, "", success_status ])
    assert_equal "cancel", evaluator.send(:fetch_ci_status, ref)

    pending_and_cancel = [ { "bucket" => "pending" }, { "bucket" => "cancel" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ pending_and_cancel, "", success_status ])
    assert_equal "pending", evaluator.send(:fetch_ci_status, ref)

    fail_and_cancel = [ { "bucket" => "fail" }, { "bucket" => "cancel" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ fail_and_cancel, "", success_status ])
    assert_equal "fail", evaluator.send(:fetch_ci_status, ref)
  end

  # ---- Merged-PR automated message ----

  test "evaluate tells a running session, once, when its PR goes open to merged" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({ MERGED_PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merged_notified"])

    messages = @session_with_pr.enqueued_messages.pending.to_a
    assert_equal 1, messages.size, "Expected exactly one enqueued message for the merge"
    assert_includes messages.first.content, "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]"
    assert_includes messages.first.content, MERGED_PR_URL
    assert_includes messages.first.content, "has been merged"
    assert_equal 1, @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%").count

    # The next poll still reads "merged" — it must not re-notify.
    evaluate(Session.find(@session_with_pr.id), "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal 1, @session_with_pr.enqueued_messages.pending.count,
      "The merged message must be delivered once per PR, not on every poll"
    assert_equal 1, @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%").count
  end

  test "evaluate sends the merged message immediately to a session in needs_input" do
    @session_with_pr.update!(status: :needs_input, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    AgentSessionJob.stubs(:enqueue_with_prompt)

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal "running", @session_with_pr.status,
      "A parked session should be woken by the merge rather than left in needs_input"
    assert @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%sent immediately%").exists?
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "An immediately-delivered message must not also be queued"
  end

  test "evaluate says nothing about a PR that was already merged and notified" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "merged" },
      "github_pull_request_merged_notified" => { MERGED_PR_URL => true }
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    refute @session_with_pr.enqueued_messages.pending.exists?
    refute @session_with_pr.logs.where("content LIKE ?", "%PR merged:%").exists?
  end

  test "evaluate does not announce a PR that was already merged the first time it is seen" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ]
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "A PR already merged before the first poll is not this session's merge event"
  end

  test "evaluate announces only the PR that merged when a session has several" do
    merged = "https://github.com/owner/repo/pull/102"
    still_open = "https://github.com/owner/repo/pull/103"
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ merged, still_open ],
      "github_pull_request_statuses" => { merged => "open", still_open => "open" }
    })

    evaluate(@session_with_pr, { merged => "merged", still_open => "open" }, evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({ merged => "merged", still_open => "open" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({ merged => true }, @session_with_pr.custom_metadata["github_pull_request_merged_notified"])

    messages = @session_with_pr.enqueued_messages.pending.to_a
    assert_equal 1, messages.size
    assert_includes messages.first.content, merged
    refute_includes messages.first.content, still_open
  end

  test "evaluate does not message a session that reached a terminal state mid-poll" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    # The pass reads the session before it spends seconds talking to GitHub, so the
    # status it holds is the one from the top of the sweep. Poll a stale view of a
    # session that archived itself in the meantime — the state this guard exists for.
    stale_view = Session.find(@session_with_pr.id)
    @session_with_pr.update!(status: :archived)

    evaluate(stale_view, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    # The status is still recorded — only the message is withheld, and the PR is
    # never marked notified because it never was.
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.enqueued_messages.pending.exists?
    refute @session_with_pr.logs.where("content LIKE ?", "%PR merged:%").exists?
  end

  test "evaluate queues the merged message for a waiting session" do
    @session_with_pr.update!(status: :waiting, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal "waiting", @session_with_pr.status,
      "A sleeping session is not woken by the poller — the message waits for its next turn"
    assert_equal 1, @session_with_pr.enqueued_messages.pending.count
    assert @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%enqueued%").exists?
  end

  test "evaluate says nothing when a PR is closed without merging" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    evaluate(@session_with_pr, "closed", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "closed" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "Only a merge is worth interrupting a session for"
  end

  test "evaluate announces two PRs that merge in the same poll" do
    first = "https://github.com/owner/repo/pull/201"
    second = "https://github.com/owner/repo/pull/202"
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ first, second ],
      "github_pull_request_statuses" => { first => "open", second => "open" }
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_equal({ first => true, second => true }, @session_with_pr.custom_metadata["github_pull_request_merged_notified"])

    # Two deliveries against one session in a single sweep: each takes its own lock and
    # its own position, so neither overwrites the other.
    contents = @session_with_pr.enqueued_messages.pending.order(:position).pluck(:content)
    assert_equal 2, contents.size
    assert contents.any? { |c| c.include?(first) }
    assert contents.any? { |c| c.include?(second) }
    assert_equal [ 1, 2 ], @session_with_pr.enqueued_messages.pending.order(:position).pluck(:position)
  end

  test "evaluate does not record a PR as notified when delivery failed" do
    @session_with_pr.update!(status: :needs_input, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    # Delivery blows up mid-transaction. The evaluator swallows it — one session that
    # cannot take a message must not abort the sweep — but the marker must not then
    # claim a notification that never left.
    Session.any_instance.stubs(:deliver_follow_up!).raises(RuntimeError, "boom")

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    @session_with_pr.reload
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.logs.where("content LIKE ?", "%PR merged:%").exists?,
      "The log entry is written inside the delivery transaction and must roll back with it"
  end

  test "pr_merged_message names the PR and both outcomes" do
    message = AutomatedPrompts.pr_merged_message(MERGED_PR_URL)

    assert_includes message, "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]"
    assert_includes message, MERGED_PR_URL
    assert_includes message, "has been merged"
    assert_match(/archive this session/i, message)
    assert_match(/waiting on this merge/i, message)
    # An outstanding human request outranks archiving — say so, or the session
    # can close itself on top of a question nobody answered.
    assert_match(/outranks archiving/i, message)
  end

  # The queue could not tell Zimmer's own notices from a caller's, and a reader
  # of a retired queue must: a session archiving over this message is complying
  # with it, not discarding something somebody is waiting on. See
  # EnqueuedMessage::ORIGINS.
  test "a queued merged-PR notice is stamped with its origin" do
    @session_with_pr.update!(status: :running)

    Github::PrStatusEvaluator.new.send(
      :notify_merged_prs, @session_with_pr, [ "https://github.com/owner/repo/pull/1" ]
    )

    message = @session_with_pr.enqueued_messages.sole
    assert_equal "automated_pr_merged", message.origin
  end

  # ---- What the merge fired (tadasant/tadasant-internal#1969) ----

  test "the merged message names post-merge runs still in flight and tells the session to wait" do
    track_open_pr

    Github::PrStatusEvaluator.any_instance.stubs(:post_merge_automation).returns({
      merge_commit_sha: "deadbee",
      runs: [
        { "name" => "Release image", "status" => "in_progress", "conclusion" => nil,
          "url" => "https://github.com/owner/repo/actions/runs/1" }
      ]
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    content = @session_with_pr.reload.enqueued_messages.pending.sole.content
    assert_includes content, "Release image"
    assert_includes content, "https://github.com/owner/repo/actions/runs/1"
    assert_includes content, "Wait for those runs before you archive"
    assert_includes content, "wake_me_up_later"
    assert_includes content, "Do NOT park in `needs_input` for it"
  end

  test "the merged message reports a post-merge run that already failed" do
    track_open_pr

    Github::PrStatusEvaluator.any_instance.stubs(:post_merge_automation).returns({
      merge_commit_sha: "deadbee",
      runs: [
        { "name" => "Deploy production", "status" => "completed", "conclusion" => "failure",
          "url" => "https://github.com/owner/repo/actions/runs/2" }
      ]
    })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    content = @session_with_pr.reload.enqueued_messages.pending.sole.content
    assert_includes content, "already FAILED"
    assert_includes content, "Deploy production"
    assert_includes content, "https://github.com/owner/repo/actions/runs/2"
  end

  # The constraint that matters as much as the fix: a PR that fires nothing must
  # still archive on the merge message, with no wait and nothing to sleep on.
  test "an ordinary merge that fired nothing still says archive now" do
    track_open_pr

    Github::PrStatusEvaluator.any_instance.stubs(:post_merge_automation)
      .returns({ merge_commit_sha: "deadbee", runs: [] })

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    content = @session_with_pr.reload.enqueued_messages.pending.sole.content
    assert_includes content, "option 1 below applies as written: archive"
    assert_includes content, "gh run list --commit deadbee --repo owner/repo"
    refute_includes content, "Wait for those runs before you archive",
      "A merge that fired nothing must not put the session into a deploy wait"
  end

  # Failing open: a lookup GitHub would not answer must leave the session the message
  # it has always had rather than a hedge it cannot act on.
  test "a merge whose commit could not be read sends the message unchanged" do
    track_open_pr

    evaluate(@session_with_pr, "merged", evaluator: NoChecks.new)

    content = @session_with_pr.reload.enqueued_messages.pending.sole.content
    assert_equal AutomatedPrompts.pr_merged_message(MERGED_PR_URL), content
  end

  # The lookup is two `gh` calls, and it must stay on the once-per-PR transition
  # rather than joining the 30-second pass.
  test "an open PR costs no post-merge lookup" do
    track_open_pr

    evaluator = PassingChecks.new
    evaluator.expects(:post_merge_automation).never

    evaluate(@session_with_pr, "open", evaluator: evaluator)
  end

  test "fetch_merge_commit_sha reads the oid, and answers nil when gh fails" do
    evaluator = Github::PrStatusEvaluator.new

    BoundedSubprocess.stubs(:run).returns(
      [ { "mergeCommit" => { "oid" => "abc1234" } }.to_json, "", fake_process_status ]
    )
    assert_equal "abc1234", evaluator.send(:fetch_merge_commit_sha, ref)

    # A PR merged with no merge commit recorded, and a call that did not complete,
    # are both "nothing true to say" rather than a claim.
    BoundedSubprocess.stubs(:run).returns([ { "mergeCommit" => nil }.to_json, "", fake_process_status ])
    assert_nil evaluator.send(:fetch_merge_commit_sha, ref)

    BoundedSubprocess.stubs(:run).returns([ "", "boom", fake_process_status(exitstatus: 1) ])
    assert_nil evaluator.send(:fetch_merge_commit_sha, ref)
  end

  test "fetch_post_merge_runs returns the runs, and nil when the call did not complete" do
    evaluator = Github::PrStatusEvaluator.new
    runs = [ { "name" => "CI", "status" => "queued", "conclusion" => nil, "url" => "https://x/1" } ]

    BoundedSubprocess.stubs(:run).returns([ runs.to_json, "", fake_process_status ])
    assert_equal runs, evaluator.send(:fetch_post_merge_runs, ref, "abc1234")

    # An empty list is an answer: this merge fired nothing GitHub has created yet.
    BoundedSubprocess.stubs(:run).returns([ "[]", "", fake_process_status ])
    assert_equal [], evaluator.send(:fetch_post_merge_runs, ref, "abc1234")

    BoundedSubprocess.stubs(:run).returns([ "", "boom", fake_process_status(exitstatus: 1) ])
    assert_nil evaluator.send(:fetch_post_merge_runs, ref, "abc1234")

    BoundedSubprocess.stubs(:run).returns([ "not json", "", fake_process_status ])
    assert_nil evaluator.send(:fetch_post_merge_runs, ref, "abc1234")
  end

  test "post_merge_automation asks GitHub about the merge commit, then about its runs" do
    Github::PrStatusEvaluator.any_instance.unstub(:post_merge_automation)

    evaluator = Github::PrStatusEvaluator.new
    evaluator.stubs(:fetch_merge_commit_sha).returns("abc1234")
    evaluator.stubs(:fetch_post_merge_runs).returns([ { "name" => "CI" } ])

    assert_equal(
      { merge_commit_sha: "abc1234", runs: [ { "name" => "CI" } ] },
      evaluator.send(:post_merge_automation, MERGED_PR_URL)
    )

    # An unreadable merge commit stops the second call from being worth making.
    evaluator.stubs(:fetch_merge_commit_sha).returns(nil)
    evaluator.expects(:fetch_post_merge_runs).never
    assert_equal({ merge_commit_sha: nil, runs: [] }, evaluator.send(:post_merge_automation, MERGED_PR_URL))
  end

  # ---- Hung gh call (#458) ----

  test "fetch_ci_status treats a nil status as a failure, not as the exit-8 pending code" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: connection reset", nil ])

    result = nil
    assert_nothing_raised { result = Github::PrStatusEvaluator.new.send(:fetch_ci_status, ref) }

    # The success? / exitstatus == 8 line dereferenced the nil twice. Neither branch may
    # be taken: an unknown exit code is not the "checks pending" code, and it is not
    # "this PR has no checks" either.
    assert_equal Github::PrStatusEvaluator::CI_STATUS_UNKNOWN, result
  end

  test "fetch_ci_status still treats a real exit 8 as pending checks" do
    checks = [ { "bucket" => "pending" } ].to_json
    BoundedSubprocess.stubs(:run).returns([ checks, "", fake_process_status(exitstatus: 8) ])

    assert_equal "pending", Github::PrStatusEvaluator.new.send(:fetch_ci_status, ref)
  end

  test "fetch_ci_status bounds its gh call and asks for the argv it means to run" do
    BoundedSubprocess.expects(:run)
      .with([ "gh", "pr", "checks", "42", "--repo", "owner/repo", "--json", "bucket,state" ],
            timeout: Github::PrStatusEvaluator::CI_STATUS_TIMEOUT)
      .returns([ [ { "bucket" => "pass" } ].to_json, "", fake_process_status ])

    assert_equal "pass", Github::PrStatusEvaluator.new.send(:fetch_ci_status, ref)
  end

  test "fetch_ci_status treats a timed-out gh call as a failure, not as the exit-8 pending code" do
    BoundedSubprocess.stubs(:run).raises(
      BoundedSubprocess::TimeoutError,
      "command timed out after #{Github::PrStatusEvaluator::CI_STATUS_TIMEOUT}s (process group killed): gh pr checks"
    )

    result = nil
    assert_nothing_raised { result = Github::PrStatusEvaluator.new.send(:fetch_ci_status, ref) }

    # A timeout has no exit code at all, so the `exit_code == 8` branch must not be
    # taken: a hang is not evidence that checks are pending. Nor is it evidence the PR
    # has no checks — that is what CI_STATUS_UNKNOWN keeps separate from nil.
    assert_equal Github::PrStatusEvaluator::CI_STATUS_UNKNOWN, result
  end

  test "evaluate keeps a recorded CI status when the checks call cannot be read" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" },
      "github_pull_request_ci_statuses" => { MERGED_PR_URL => "fail" }
    })

    # The PR reads open; only the CI call hangs. Clearing the recorded "fail" here would
    # publish "this PR has no checks" off the back of a call we never completed — the UI
    # reads this key, so a red PR would silently stop looking red.
    BoundedSubprocess.expects(:run).at_least_once
      .raises(BoundedSubprocess::TimeoutError, "command timed out after 30s (process group killed): gh pr checks")

    assert_nothing_raised { evaluate(@session_with_pr, "open") }

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "fail" }, @session_with_pr.custom_metadata["github_pull_request_ci_statuses"])
  end

  test "evaluate clears a recorded CI status when GitHub says there are no checks" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" },
      "github_pull_request_ci_statuses" => { MERGED_PR_URL => "fail" }
    })

    # The other side of the distinction: an answered call with an empty checks array is
    # a real reading, and it still clears.
    BoundedSubprocess.stubs(:run).returns([ "[]", "", fake_process_status(exitstatus: 0) ])

    evaluate(@session_with_pr, "open")

    @session_with_pr.reload
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_ci_statuses"])
  end

  private

  def ref
    Github::PrRef.parse("https://github.com/owner/repo/pull/42")
  end

  def track_open_pr
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })
  end

  # Run the evaluator over a session's tracked PRs.
  #
  # `reading` is what this pass's `gh pr view` came back with for each PR: a status
  # string for all of them, or a Hash keyed by url. nil is "the call did not complete",
  # which is the nil snapshot the pass hands over.
  def evaluate(session, reading, evaluator: Github::PrStatusEvaluator.new)
    refs = Github::PrRef.for_session(session)
    snapshots = refs.to_h do |pr_ref|
      status = reading.is_a?(Hash) ? reading[pr_ref.url] : reading
      [ pr_ref.url, snapshot_for(pr_ref, status) ]
    end
    evaluator.evaluate(session, refs, snapshots)
  end

  def snapshot_for(pr_ref, status)
    return nil if status.nil?

    state, merged_at = case status
    when "merged" then [ "MERGED", "2025-01-01T12:00:00Z" ]
    when "open" then [ "OPEN", nil ]
    when "closed" then [ "CLOSED", nil ]
    else raise ArgumentError, "unknown status #{status.inspect}"
    end

    Github::PrSnapshot.new(ref: pr_ref, state: state, merged_at: merged_at, mergeable: "MERGEABLE")
  end

  # Evaluators whose CI reading is fixed, so a status test is not also a CI test.
  class NoChecks < Github::PrStatusEvaluator
    def fetch_ci_status(_ref)
      nil
    end
  end

  class PendingChecks < Github::PrStatusEvaluator
    def fetch_ci_status(_ref)
      "pending"
    end
  end

  class PassingChecks < Github::PrStatusEvaluator
    def fetch_ci_status(_ref)
      "pass"
    end
  end
end
