# frozen_string_literal: true

require "test_helper"
require "support/issues_helpers"

# The GitHub read. Nothing here calls GitHub — GithubSearchService is stubbed at
# the same seam the PR poller's tests use — because the properties worth pinning
# are about how a failure is reported, not about what GitHub says today.
class Issues::GithubSnapshotTest < ActiveSupport::TestCase
  include IssuesHelpers

  test "transforms search results into issues, and drops pull requests" do
    raw = stub_search({
      "tadasant/zimmer" => [ search_item(number: 1, labels: %w[bug convergent]),
                             search_item(number: 2, pull_request: true) ]
    })

    issues = Issues::GithubSnapshot.send(:hydrate, raw).issues.select { |i| i.repo == "tadasant/zimmer" }

    assert_equal [ 1 ], issues.map(&:number)
    assert_equal %w[bug convergent], issues.first.labels
    assert_equal "zimmer#1", issues.first.key
    assert issues.first.open?
  end

  test "an issue that both searches return is counted once" do
    raw = stub_search({ "tadasant/zimmer" => [ search_item(number: 7) ] }, both: true)

    assert_equal 1, Issues::GithubSnapshot.send(:hydrate, raw).issues.count { |i| i.repo == "tadasant/zimmer" }
  end

  test "one repo failing costs only that repo, and is named rather than rendered as zero issues" do
    raw = with_preflight_ok do
      GithubSearchService.stub(:search_issues, ->(query) {
        raise GithubSearchService::SearchError, "boom" if query.include?("tadasant/motet")

        query.include?("tadasant/zimmer") ? [ search_item(number: 1) ] : []
      }) { Issues::GithubSnapshot.load_from_github }
    end

    snapshot = Issues::GithubSnapshot.send(:hydrate, raw)
    assert snapshot.failed?
    assert_equal [ "tadasant/motet" ], snapshot.errors.keys
    assert_match "boom", snapshot.errors["tadasant/motet"]
    assert_equal 1, snapshot.issues.length, "the other four repos still answered"
    assert_not_includes snapshot.repos, "tadasant/motet"
  end

  test "an unexpected error in one repo is caught rather than 500ing the page" do
    raw = with_preflight_ok do
      GithubSearchService.stub(:search_issues, ->(_query) { raise Errno::ENOENT, "gh" }) do
        Issues::GithubSnapshot.load_from_github
      end
    end

    snapshot = Issues::GithubSnapshot.send(:hydrate, raw)
    assert_equal Issues::GithubSnapshot::REPOS.sort, snapshot.errors.keys.sort
    assert_empty snapshot.issues
  end

  test "a credential GitHub refused names every repo with the reason, not an empty page" do
    preflight = GithubSearchService::PreflightResult.new(GithubSearchService::PREFLIGHT_REJECTED, "Bad credentials")
    raw = GithubSearchService.stub(:auth_preflight, preflight) { Issues::GithubSnapshot.load_from_github }
    snapshot = Issues::GithubSnapshot.send(:hydrate, raw)

    assert_equal Issues::GithubSnapshot::REPOS.sort, snapshot.errors.keys.sort
    assert_match "Bad credentials", snapshot.credential_detail
  end

  test "the closed-issue search covers the widest window the page offers" do
    queries = []
    with_preflight_ok do
      GithubSearchService.stub(:search_issues, ->(query) { queries << query; [] }) do
        Issues::GithubSnapshot.load_from_github
      end
    end

    closed = queries.grep(/is:closed/).first
    assert_match "closed:>=#{(Date.current - Issues::GithubSnapshot::WINDOWS.max).iso8601}", closed
    assert_equal Issues::GithubSnapshot::REPOS.length * 2, queries.length, "two searches per repo, no more"
  end

  test "the cache round trip survives plain hashes and rebuilds the value objects" do
    raw = stub_search({ "tadasant/zimmer" => [ search_item(number: 1, closed_at: "2026-08-01T00:00:00Z", state: "closed") ] })
    round_tripped = Issues::GithubSnapshot.send(:hydrate, JSON.parse(raw.to_json))
    issue = round_tripped.issues.first

    assert_kind_of Issues::GithubIssue, issue
    assert_equal Time.iso8601("2026-08-01T00:00:00Z"), issue.closed_at
    assert_not issue.open?
  end

  test "hydrating nothing gives an empty snapshot rather than raising" do
    snapshot = Issues::GithubSnapshot.send(:hydrate, nil)

    assert_empty snapshot.issues
    assert_not snapshot.failed?
  end

  private

  def with_preflight_ok(&block)
    preflight = GithubSearchService::PreflightResult.new(GithubSearchService::PREFLIGHT_AUTHENTICATED, "ok")
    GithubSearchService.stub(:auth_preflight, preflight, &block)
  end

  # @param both [Boolean] return the same items from the open AND closed search
  def stub_search(per_repo, both: false)
    with_preflight_ok do
      GithubSearchService.stub(:search_issues, ->(query) {
        repo = per_repo.keys.find { |name| query.include?(name) }
        next [] if repo.nil?
        next [] if !both && query.include?("is:closed")

        per_repo.fetch(repo)
      }) { Issues::GithubSnapshot.load_from_github }
    end
  end

  def search_item(number:, labels: [], state: "open", closed_at: nil, pull_request: false)
    item = {
      "number" => number, "title" => "Issue #{number}", "state" => state,
      "html_url" => "https://github.com/tadasant/zimmer/issues/#{number}",
      "created_at" => "2026-07-01T00:00:00Z", "closed_at" => closed_at,
      "labels" => labels.map { |name| { "name" => name } }
    }
    item["pull_request"] = { "url" => "x" } if pull_request
    item
  end
end
