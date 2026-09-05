require "test_helper"
require "mocha/minitest"

class Github::PrSnapshotTest < ActiveSupport::TestCase
  REF = Github::PrRef.parse("https://github.com/owner/repo/pull/42")

  # ---- the widened call ----

  test "fetch asks for one PR object with every field the pass needs" do
    BoundedSubprocess.expects(:run)
      .with([ "gh", "pr", "view", "42", "--repo", "owner/repo", "--json", "state,mergedAt,mergeable" ],
            timeout: Github::PrSnapshot::TIMEOUT)
      .returns([ { "state" => "OPEN", "mergedAt" => nil, "mergeable" => "MERGEABLE" }.to_json, "", fake_process_status ])

    snapshot = Github::PrSnapshot.fetch(REF)

    assert_equal "open", snapshot.status
    assert_equal false, snapshot.conflicting?
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

  private

  def build(state: "OPEN", merged_at: nil, mergeable: "MERGEABLE")
    Github::PrSnapshot.new(ref: REF, state: state, merged_at: merged_at, mergeable: mergeable)
  end
end
