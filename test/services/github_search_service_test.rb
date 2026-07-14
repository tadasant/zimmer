# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GithubSearchServiceTest < ActiveSupport::TestCase
  # A stand-in for Process::Status with a controllable #success?.
  Status = Struct.new(:success?)

  test "configured? is true when gh auth status exits 0" do
    Open3.expects(:capture3).with("gh", "auth", "status").returns([ "", "Logged in", Status.new(true) ])
    assert GithubSearchService.configured?
  end

  test "configured? is false when gh auth status exits non-zero" do
    # This is the staging failure mode: gh present but no credential.
    Open3.expects(:capture3).with("gh", "auth", "status")
      .returns([ "", "You are not logged into any GitHub hosts. To get started with GitHub CLI, please run: gh auth login", Status.new(false) ])
    assert_not GithubSearchService.configured?
  end

  test "configured? is false (not raising) when gh is not even installed" do
    Open3.expects(:capture3).with("gh", "auth", "status").raises(Errno::ENOENT, "No such file or directory - gh")
    assert_not GithubSearchService.configured?
  end

  test "repo_group ORs the repos" do
    assert_equal "(repo:owner/a OR repo:owner/b)",
                 GithubSearchService.repo_group(%w[owner/a owner/b])
  end

  test "label_group quotes each label and strips embedded quotes" do
    assert_equal %{(label:"ready to merge" OR label:"urgent")},
                 GithubSearchService.label_group([ "ready to merge", "urgent" ])
    # An embedded double quote would terminate the qualifier early; it is dropped.
    assert_equal %{(label:"weird name")},
                 GithubSearchService.label_group([ 'weird" name' ])
  end
end
