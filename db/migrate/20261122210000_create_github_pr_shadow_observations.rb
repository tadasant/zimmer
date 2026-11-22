# frozen_string_literal: true

# One change a per-session PR poll found, and whether GitHub's webhook signalled it first. Written
# while GITHUB_PR_INGEST_MODE is webhook_shadow or webhook_with_poll_fallback; read by
# compare_github_pr_webhook_shadow. See GithubPrShadowObservation.
class CreateGithubPrShadowObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_pr_shadow_observations do |t|
      t.bigint :session_id, null: false
      t.string :pr_url, null: false
      t.string :kind, null: false
      t.string :mode, null: false
      t.boolean :hit, null: false
      t.datetime :signaled_at
      t.datetime :created_at, null: false
    end

    add_index :github_pr_shadow_observations, :created_at
    add_index :github_pr_shadow_observations, %i[kind created_at]
    add_index :github_pr_shadow_observations, :session_id
  end
end
