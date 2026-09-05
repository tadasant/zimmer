# frozen_string_literal: true

require "test_helper"

class GithubPullRequestMergeabilityTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/tadasant/zimmer/pull/834"

  test "reads a mergeable PR as :mergeable" do
    stub_gh(state: "OPEN", mergeable: "MERGEABLE")
    assert_equal :mergeable, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads a conflicting PR as :conflicting" do
    stub_gh(state: "OPEN", mergeable: "CONFLICTING")
    assert_equal :conflicting, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads GitHub's still-computing UNKNOWN as :unknown" do
    stub_gh(state: "OPEN", mergeable: "UNKNOWN")
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  # The REST vocabulary this module used to speak. It reads GraphQL's MergeableState
  # now, through the same Github::PrSnapshot the merge conflict evaluator reads, so
  # "true"/"false" must never be mistaken for an answer — a `false` read as
  # "mergeable" would retire a real conflict notice forever.
  test "reads the old REST mergeable vocabulary as :unknown, never as an answer" do
    stub_gh(state: "OPEN", mergeable: true)
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)

    stub_gh(state: "OPEN", mergeable: false)
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  # A merged or closed PR reports no mergeability. Reading that as "no idea"
  # would throw away the one thing GitHub said for certain, and a session woken
  # to resolve conflicts on a merged PR is exactly the harm being avoided.
  test "a merged PR is :not_open, not :unknown, despite an absent mergeability" do
    stub_gh(state: "MERGED", merged_at: "2026-01-01T00:00:00Z", mergeable: "UNKNOWN")
    assert_equal :not_open, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a closed PR is :not_open" do
    stub_gh(state: "CLOSED", mergeable: "UNKNOWN")
    assert_equal :not_open, GithubPullRequestMergeability.read(PR_URL)
  end

  test "status outranks a stale mergeability reading on a closed PR" do
    stub_gh(state: "CLOSED", mergeable: "CONFLICTING")
    assert_equal :not_open, GithubPullRequestMergeability.read(PR_URL)
  end

  # Fails OPEN, not closed. A state this could not establish is not evidence the PR
  # is terminal, and suppressing on it would leave a session asleep on a PR that
  # will never merge.
  test "a state this cannot recognise still answers the mergeability question" do
    stub_gh(state: "DRAFT", mergeable: "CONFLICTING")
    assert_equal :conflicting, GithubPullRequestMergeability.read(PR_URL)

    stub_gh(state: nil, mergeable: "MERGEABLE")
    assert_equal :mergeable, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a failed gh call is :unknown rather than an answer" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: not authenticated", fake_process_status(exitstatus: 1) ])
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a reaped gh child (nil status) is :unknown rather than an answer" do
    BoundedSubprocess.stubs(:run).returns([ '{"state":"OPEN","mergeable":"MERGEABLE"}', "", nil ])
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a timed-out gh call is :unknown rather than raising" do
    BoundedSubprocess.stubs(:run).raises(BoundedSubprocess::TimeoutError, "command timed out after 20s")
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "an unexpected exception from the subprocess is :unknown rather than raising" do
    BoundedSubprocess.stubs(:run).raises(Errno::ENOENT, "No such file or directory - gh")
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "unparseable output is :unknown rather than raising" do
    BoundedSubprocess.stubs(:run).returns([ "not json at all", "", fake_process_status(exitstatus: 0) ])
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a string that is not a PR URL is :unknown and shells out to nothing" do
    BoundedSubprocess.expects(:run).never
    assert_equal :unknown, GithubPullRequestMergeability.read("not a url")
    assert_equal :unknown, GithubPullRequestMergeability.read(nil)
  end

  # Matches with owner == ".." and repo == "..", so it reaches the traversal
  # guard rather than the "not a PR URL" branch — which is the point.
  test "a traversal-shaped repo path is refused rather than sent to the API" do
    BoundedSubprocess.expects(:run).never
    assert_equal :unknown, GithubPullRequestMergeability.read("https://github.com/../../pull/1")
  end

  # The same call the merge conflict evaluator's pass makes, under the same bound.
  # That is the point: one reader, so the guard that RETIRES a conflict notice and
  # the evaluator that WROTE it cannot disagree about what "conflicting" means.
  test "goes through the same bounded reader the poll pass uses" do
    captured = nil
    BoundedSubprocess.stubs(:run).with do |command, **kwargs|
      captured = [ command, kwargs ]
      true
    end.returns([ '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE"}', "", fake_process_status(exitstatus: 0) ])

    GithubPullRequestMergeability.read(PR_URL)

    command, kwargs = captured
    assert_equal [ "gh", "pr", "view", "834", "--repo", "tadasant/zimmer",
                   "--json", Github::PrSnapshot::JSON_FIELDS ], command
    assert_equal Github::PrSnapshot::TIMEOUT, kwargs[:timeout]
  end

  test "only read is public" do
    assert_respond_to GithubPullRequestMergeability, :read
    refute GithubPullRequestMergeability.respond_to?(:fetch_snapshot),
      "the helpers are implementation detail, not interface"
    refute GithubPullRequestMergeability.respond_to?(:interpret)
  end

  private

  def stub_gh(state:, mergeable:, merged_at: nil)
    payload = { "state" => state, "mergedAt" => merged_at, "mergeable" => mergeable }.to_json
    BoundedSubprocess.stubs(:run).returns([ payload, "", fake_process_status(exitstatus: 0) ])
  end
end
