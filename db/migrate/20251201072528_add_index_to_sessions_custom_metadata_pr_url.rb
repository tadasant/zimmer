class AddIndexToSessionsCustomMetadataPrUrl < ActiveRecord::Migration[8.0]
  def change
    # Add partial index for efficient PR URL lookups in GitHubPullRequestPollerJob
    add_index :sessions,
      "(custom_metadata->>'github_pull_request_url')",
      name: "index_sessions_on_custom_metadata_pr_url",
      where: "custom_metadata->>'github_pull_request_url' IS NOT NULL"
  end
end
