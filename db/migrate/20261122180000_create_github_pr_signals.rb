# frozen_string_literal: true

# What GitHub's webhook has said about the pull requests sessions track: "this PR's state may
# have changed", one row per subject and kind, holding the newest time it was said. See
# GithubPrSignal.
class CreateGithubPrSignals < ActiveRecord::Migration[8.1]
  def change
    create_table :github_pr_signals do |t|
      t.string :subject, null: false
      t.string :kind, null: false
      t.datetime :signaled_at, null: false
    end

    add_index :github_pr_signals, %i[subject kind], unique: true
    add_index :github_pr_signals, :signaled_at
  end
end
