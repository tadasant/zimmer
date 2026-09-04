# frozen_string_literal: true

require "test_helper"

class GithubPullRequestMergeabilityTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/tadasant/zimmer/pull/834"

  test "reads a mergeable PR as :mergeable" do
    stub_gh("true\n")
    assert_equal :mergeable, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads a conflicting PR as :conflicting" do
    stub_gh("false\n")
    assert_equal :conflicting, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads GitHub's still-computing null as :unknown" do
    stub_gh("null\n")
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "reads an unexpected value as :unknown" do
    stub_gh("MERGEABLE\n")
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a failed gh call is :unknown rather than an answer" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: not authenticated", fake_process_status(exitstatus: 1) ])
    assert_equal :unknown, GithubPullRequestMergeability.read(PR_URL)
  end

  test "a reaped gh child (nil status) is :unknown rather than an answer" do
    BoundedSubprocess.stubs(:run).returns([ "true\n", "", nil ])
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

  test "a string that is not a PR URL is :unknown and shells out to nothing" do
    BoundedSubprocess.expects(:run).never
    assert_equal :unknown, GithubPullRequestMergeability.read("not a url")
    assert_equal :unknown, GithubPullRequestMergeability.read(nil)
  end

  test "a traversal-shaped repo path is refused rather than sent to the API" do
    BoundedSubprocess.expects(:run).never
    assert_equal :unknown, GithubPullRequestMergeability.read("https://github.com/../../etc/pull/1")
  end

  test "queries the REST mergeable field the poller reads, under a bounded subprocess" do
    captured = nil
    BoundedSubprocess.stubs(:run).with do |command, **kwargs|
      captured = [ command, kwargs ]
      true
    end.returns([ "true\n", "", fake_process_status(exitstatus: 0) ])

    GithubPullRequestMergeability.read(PR_URL)

    command, kwargs = captured
    assert_equal [ "gh", "api", "repos/tadasant/zimmer/pulls/834", "--jq", ".mergeable" ], command
    assert_equal GithubPullRequestMergeability::READ_TIMEOUT_SECONDS, kwargs[:timeout]
  end

  private

  def stub_gh(stdout)
    BoundedSubprocess.stubs(:run).returns([ stdout, "", fake_process_status(exitstatus: 0) ])
  end
end
