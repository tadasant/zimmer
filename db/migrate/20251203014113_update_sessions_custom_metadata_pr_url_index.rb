class UpdateSessionsCustomMetadataPrUrlIndex < ActiveRecord::Migration[8.0]
  def up
    # Remove old singular index if it exists
    remove_index :sessions, name: "index_sessions_on_custom_metadata_pr_url", if_exists: true

    # Add new plural index for github_pull_request_urls array
    add_index :sessions,
      "(custom_metadata->>'github_pull_request_urls')",
      name: "index_sessions_on_custom_metadata_pr_urls",
      where: "custom_metadata->>'github_pull_request_urls' IS NOT NULL"

    # Migrate existing data from singular to plural format
    execute <<~SQL
      UPDATE sessions
      SET custom_metadata = custom_metadata - 'github_pull_request_url' - 'github_pull_request_status'
        || jsonb_build_object(
          'github_pull_request_urls',
          jsonb_build_array(custom_metadata->>'github_pull_request_url')
        )
        || CASE
          WHEN custom_metadata->>'github_pull_request_status' IS NOT NULL THEN
            jsonb_build_object(
              'github_pull_request_statuses',
              jsonb_build_object(
                custom_metadata->>'github_pull_request_url',
                custom_metadata->>'github_pull_request_status'
              )
            )
          ELSE '{}'::jsonb
        END
      WHERE custom_metadata->>'github_pull_request_url' IS NOT NULL
    SQL
  end

  def down
    # Remove new plural index
    remove_index :sessions, name: "index_sessions_on_custom_metadata_pr_urls", if_exists: true

    # Re-add old singular index
    add_index :sessions,
      "(custom_metadata->>'github_pull_request_url')",
      name: "index_sessions_on_custom_metadata_pr_url",
      where: "custom_metadata->>'github_pull_request_url' IS NOT NULL"

    # Migrate data back from plural to singular (take first URL)
    execute <<~SQL
      UPDATE sessions
      SET custom_metadata = custom_metadata - 'github_pull_request_urls' - 'github_pull_request_statuses'
        || jsonb_build_object(
          'github_pull_request_url',
          custom_metadata->'github_pull_request_urls'->>0
        )
        || CASE
          WHEN custom_metadata->'github_pull_request_statuses'->(custom_metadata->'github_pull_request_urls'->>0) IS NOT NULL THEN
            jsonb_build_object(
              'github_pull_request_status',
              custom_metadata->'github_pull_request_statuses'->(custom_metadata->'github_pull_request_urls'->>0)
            )
          ELSE '{}'::jsonb
        END
      WHERE custom_metadata->>'github_pull_request_urls' IS NOT NULL
    SQL
  end
end
