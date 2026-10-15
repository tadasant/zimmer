require "test_helper"
require "mocha/minitest"

class Github::PrSnapshotTest < ActiveSupport::TestCase
  REF = Github::PrRef.parse("https://github.com/owner/repo/pull/42")

  # ---- the widened call ----

  test "fetch asks for one PR object with every field the pass needs" do
    BoundedSubprocess.expects(:run)
      .with([ "gh", "pr", "view", "42", "--repo", "owner/repo", "--json", "state,mergedAt,mergeable,body,labels,headRefOid" ],
            timeout: Github::PrSnapshot::TIMEOUT)
      .returns([ { "state" => "OPEN", "mergedAt" => nil, "mergeable" => "MERGEABLE" }.to_json, "", fake_process_status ])

    snapshot = Github::PrSnapshot.fetch(REF)

    assert_equal "open", snapshot.status
    assert_equal false, snapshot.conflicting?
  end

  # `body` and `labels` ride the same call, for Github::GoalFactsEvaluator.
  test "fetch reads the description and the label names" do
    BoundedSubprocess.stubs(:run).returns([
      {
        "state" => "OPEN", "mergedAt" => nil, "mergeable" => "MERGEABLE",
        "body" => "## Verification\n- [x] CI green",
        "labels" => [ { "id" => "L1", "name" => "ready to merge", "color" => "0e8a16" }, { "name" => "bug" } ]
      }.to_json,
      "", fake_process_status
    ])

    snapshot = Github::PrSnapshot.fetch(REF)

    assert_equal "## Verification\n- [x] CI green", snapshot.body
    assert_equal [ "ready to merge", "bug" ], snapshot.labels
  end

  test "a reading built without a body says it has not read one" do
    snapshot = build(state: "OPEN")

    assert_nil snapshot.body
    assert_equal [], snapshot.labels
  end

  # ---- status mapping (unchanged from the PR poller's own) ----

  test "status reads merged from mergedAt, not from state" do
    assert_equal "merged", build(state: "MERGED", merged_at: "2025-01-01T12:00:00Z").status
    # A PR whose state has not caught up but whose mergedAt is set is still merged.
    assert_equal "merged", build(state: "OPEN", merged_at: "2025-01-01T12:00:00Z").status
  end

  test "status maps open and closed, and answers nil for anything else" do
    assert_equal "open", build(state: "OPEN").status
    assert_equal "closed", build(state: "CLOSED").status
    assert_nil build(state: "DRAFT").status
    assert_nil build(state: nil).status
  end

  # ---- mergeable mapping: REWRITTEN, not renamed ----
  #
  # The merge conflict poller read REST's `mergeable`, which answers "true"/"false"/
  # "null". This reads GraphQL's MergeableState, which answers MERGEABLE/CONFLICTING/
  # UNKNOWN — different strings, and UNKNOWN carries REST null's meaning.

  test "conflicting? maps GraphQL MergeableState, not the REST boolean" do
    assert_equal true, build(mergeable: "CONFLICTING").conflicting?
    assert_equal false, build(mergeable: "MERGEABLE").conflicting?
    assert_nil build(mergeable: "UNKNOWN").conflicting?, "UNKNOWN is REST's null: no reading yet"
    assert_nil build(mergeable: nil).conflicting?
  end

  test "conflicting? never reads the REST strings as an answer" do
    # The one mapping bug this rewrite could have: carrying the old vocabulary over.
    # "false" must not be read as clean, and "true" must not be read as conflicting.
    assert_nil build(mergeable: "true").conflicting?
    assert_nil build(mergeable: "false").conflicting?
    assert_nil build(mergeable: "null").conflicting?
  end

  # ---- a call that did not complete is never an answer ----

  test "fetch answers nil when the gh call fails" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: not found", fake_process_status(exitstatus: 1) ])

    assert_nil Github::PrSnapshot.fetch(REF)
  end

  test "fetch answers nil when the gh child's exit status was lost" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: connection reset", nil ])

    result = nil
    assert_nothing_raised { result = Github::PrSnapshot.fetch(REF) }
    assert_nil result, "an unverifiable gh call must not report a PR state"
  end

  test "fetch treats a timed-out gh call as a failure, never as a missing PR" do
    BoundedSubprocess.stubs(:run).raises(
      BoundedSubprocess::TimeoutError,
      "command timed out after #{Github::PrSnapshot::TIMEOUT}s (process group killed): gh pr view"
    )

    result = nil
    assert_nothing_raised { result = Github::PrSnapshot.fetch(REF) }
    assert_nil result
  end

  test "fetch answers nil on unparseable output" do
    BoundedSubprocess.stubs(:run).returns([ "not json", "", fake_process_status ])

    assert_nil Github::PrSnapshot.fetch(REF)
  end

  # ---- the head commit ----

  test "fetch reads the head commit, for the conflict evaluator's re-arm" do
    BoundedSubprocess.stubs(:run).returns([
      { "state" => "OPEN", "mergedAt" => nil, "mergeable" => "MERGEABLE", "headRefOid" => "abc123" }.to_json,
      "", fake_process_status
    ])

    assert_equal "abc123", Github::PrSnapshot.fetch(REF).head_sha
  end

  # ---- REST mergeability ----
  #
  # The conflict question is answered by REST's `mergeable`, the reading the old
  # merge-conflict poller trusted. GraphQL's answer stands when REST cannot be read.

  REST_COMMAND = [ "gh", "api", "repos/owner/repo/pulls/42", "--jq", ".mergeable" ].freeze

  test "with_rest_mergeability takes REST's answer over GraphQL's" do
    BoundedSubprocess.expects(:run).with(REST_COMMAND, timeout: Github::PrSnapshot::TIMEOUT)
      .returns([ "false\n", "", fake_process_status ])

    refreshed = build(mergeable: "MERGEABLE", head_sha: "abc123").with_rest_mergeability

    assert_equal true, refreshed.conflicting?
    assert_equal "abc123", refreshed.head_sha
    assert_equal "open", refreshed.status
  end

  test "with_rest_mergeability maps REST's three answers" do
    { "true" => false, "false" => true, "null" => nil }.each do |rest, conflicting|
      BoundedSubprocess.stubs(:run).returns([ "#{rest}\n", "", fake_process_status ])

      reading = build(mergeable: "UNKNOWN").with_rest_mergeability.conflicting?
      conflicting.nil? ? assert_nil(reading, rest) : assert_equal(conflicting, reading, rest)
    end
  end

  test "with_rest_mergeability keeps GraphQL's answer when REST cannot be read" do
    BoundedSubprocess.stubs(:run).returns([ "", "HTTP 502", fake_process_status(exitstatus: 1) ])

    assert_equal true, build(mergeable: "CONFLICTING").with_rest_mergeability.conflicting?
  end

  test "with_rest_mergeability asks nothing about a PR that is not open" do
    BoundedSubprocess.expects(:run).never

    snapshot = build(state: "MERGED", merged_at: "2025-01-01T12:00:00Z", mergeable: "UNKNOWN")

    assert_same snapshot, snapshot.with_rest_mergeability
  end

  test "fetch_rest_mergeable refuses a traversal-shaped repository" do
    BoundedSubprocess.expects(:run).never

    ref = Github::PrRef.new(url: "https://github.com/../x/pull/1", owner: "..", repo: "x", number: "1")

    assert_nil Github::PrSnapshot.fetch_rest_mergeable(ref)
  end

  private

  def build(state: "OPEN", merged_at: nil, mergeable: "MERGEABLE", head_sha: nil)
    Github::PrSnapshot.new(ref: REF, state: state, merged_at: merged_at, mergeable: mergeable, head_sha: head_sha)
  end
end
