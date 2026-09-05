require "test_helper"

class Github::PrRefTest < ActiveSupport::TestCase
  # The parse used to be a verbatim triple, one copy per poller job. It is one copy
  # now, so it is pinned in one place.
  test "parse pulls owner, repo and number out of a PR url" do
    cases = [
      [ "https://github.com/owner/repo/pull/123", "owner", "repo", "123" ],
      [ "https://github.com/my-org/my-repo/pull/456", "my-org", "my-repo", "456" ],
      [ "https://github.com/user_123/project-name/pull/999", "user_123", "project-name", "999" ]
    ]

    cases.each do |url, owner, repo, number|
      ref = Github::PrRef.parse(url)
      assert_not_nil ref, "Failed to parse #{url}"
      assert_equal owner, ref.owner
      assert_equal repo, ref.repo
      assert_equal number, ref.number
      assert_equal url, ref.url
      assert_equal "#{owner}/#{repo}", ref.slug
    end
  end

  test "parse answers nil for anything that is not a PR url" do
    [ nil, "", "https://github.com/owner/repo", "https://github.com/owner/repo/issues/1",
      "https://gitlab.com/owner/repo/pull/1", "https://github.com/owner/repo/pull/abc" ].each do |url|
      assert_nil Github::PrRef.parse(url), "#{url.inspect} should not parse"
    end
  end

  test "for_session resolves every tracked url, in order, and drops the unparseable" do
    session = sessions(:with_pr_url)
    session.update!(custom_metadata: {
      "github_pull_request_urls" => [
        "https://github.com/owner/repo/pull/2",
        "not a url",
        "https://github.com/owner/repo/pull/1"
      ]
    })

    refs = Github::PrRef.for_session(session)

    assert_equal %w[2 1], refs.map(&:number)
  end

  # Nothing stops the same url being recorded twice — `github_pull_request_urls` is an
  # array a transcript hook appends to. Under the three separate pollers a duplicate
  # cost a second `gh` call for a PR already read AND a second merged-PR message for
  # one merge, because the "was it open last time" test reads the stored statuses hash
  # rather than the one being built.
  test "for_session resolves a duplicated url once" do
    session = sessions(:with_pr_url)
    url = "https://github.com/owner/repo/pull/1"
    session.update!(custom_metadata: { "github_pull_request_urls" => [ url, url ] })

    assert_equal [ url ], Github::PrRef.for_session(session).map(&:url)
  end

  test "for_session answers empty when the session tracks nothing, or tracks a non-array" do
    session = sessions(:running)
    assert_equal [], Github::PrRef.for_session(session)

    session.update!(custom_metadata: { "github_pull_request_urls" => "https://github.com/o/r/pull/1" })
    assert_equal [], Github::PrRef.for_session(session)
  end
end
