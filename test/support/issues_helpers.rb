# frozen_string_literal: true

# Builders for the Issues page's tests. GitHub is never called: a snapshot is
# assembled from literal issues, which is the only way to write a deterministic
# test about "what is open on GitHub today".
module IssuesHelpers
  def github_issue(repo: "tadasant/zimmer", number: 1, title: nil, state: "open",
                   created_at: 30.days.ago, closed_at: nil, labels: [])
    Issues::GithubIssue.new(
      repo: repo,
      number: number,
      title: title || "Issue #{number}",
      url: "https://github.com/#{repo}/issues/#{number}",
      state: state,
      created_at: created_at&.to_time,
      closed_at: closed_at&.to_time,
      labels: labels
    )
  end

  def github_snapshot(issues: [], fetched_at: Time.current, errors: {})
    Issues::GithubSnapshot::Snapshot.new(issues: issues, fetched_at: fetched_at, errors: errors)
  end

  # Runs the block with Issues::GithubSnapshot.fetch answering with `snapshot`,
  # so a controller test never shells out to `gh`.
  def with_github_snapshot(snapshot)
    Issues::GithubSnapshot.stub(:fetch, ->(**) { snapshot }) { yield }
  end
end
