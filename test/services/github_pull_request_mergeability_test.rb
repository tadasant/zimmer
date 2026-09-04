# frozen_string_literal: true

require "test_helper"

class GithubPullRequestMergeabilityTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/tadasant/zimmer/pull/834"

  test "reads a mergeable PR as :mergeable" do
    stub_gh(state: "open", mergeable: true)
    assert_equal :mergeable, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads a conflicting PR as :conflicting" do
    stub_gh(state: "open", mergeable: false)
    assert_equal :conflicting, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads GitHub's still-computing null as :unknown" do
    stub_gh(state: "open", mergeable: nil)
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads an unexpected mergeable value as :unknown" do
    stub_gh(state: "open", mergeable: "MERGEABLE")
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  # A merged or closed PR reports mergeable: null. Reading that as "no idea"
  # would throw away the one thing GitHub said for certain, and a session woken
  # to resolve conflicts on a merged PR is exactly the harm being avoided.
  test "a merged PR is :not_open, not :unknown, despite a null mergeable" do
    stub_gh(state: "closed", mergeable: nil)
    assert_equal :not_open, GithubPullRequestMergeability.read(PR_URL)
  end

  test "state outranks a stale mergeable reading on a closed PR" do
    stub_gh(state: "closed", mergeable: false)
    assert_equal :not_open, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a failed gh call is :unknown rather than an answer" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: not authenticated", fake_process_status(exitstatus: 1) ])
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a reaped gh child (nil status) is :unknown rather than an answer" do
    BoundedSubprocess.stubs(:run).returns([ '{"state":"open","mergeable":true}', "", nil ])
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

  test "queries the REST fields the poller reads, under a bounded subprocess" do
    captured = nil
    BoundedSubprocess.stubs(:run).with do |command, **kwargs|
      captured = [ command, kwargs ]
      true
    end.returns([ '{"state":"open","mergeable":true}', "", fake_process_status(exitstatus: 0) ])

    GithubPullRequestMergeability.read(PR_URL)

    command, kwargs = captured
    assert_equal [ "gh", "api", "repos/tadasant/zimmer/pulls/834",
                   "--jq", "{state: .state, mergeable: .mergeable}" ], command
    assert_equal GithubPullRequestMergeability::READ_TIMEOUT_SECONDS, kwargs[:timeout]
  end

  test "only read is public" do
    assert_respond_to GithubPullRequestMergeability, :read
    refute GithubPullRequestMergeability.respond_to?(:fetch_pull_request),
      "the helpers are implementation detail, not interface"
    refute GithubPullRequestMergeability.respond_to?(:interpret)
  end

  private

  def stub_gh(state:, mergeable:)
    payload = { "state" => state, "mergeable" => mergeable }.to_json
    BoundedSubprocess.stubs(:run).returns([ payload, "", fake_process_status(exitstatus: 0) ])
  end
end
