# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# The named humans this deployment knows about.
#
# Existing rows are left ALONE — `slack_user_ids` and `notes` are edited at
# /supervisor/users, and a re-run of `db:seed` must not undo that. The same two
# rows are inserted by the migration that creates the table (a deployment with
# an existing database never runs seeds), so this is the fresh-install path.
User::SEEDED.each do |attrs|
  next if User.exists?(key: attrs[:key])

  User.create!(**attrs)
end

# The Trigger that turns the `account_needs_reauth` event into a Slack DM.
#
# The mirror image of the User rows above: the migration covers a deployment with
# an existing database, and this covers the fresh install, where `db:prepare`
# loads `schema.rb` instead of running migrations and the migration therefore
# never executes.
#
# The migration is invoked rather than reimplemented, so the row has exactly one
# definition. Its `up` is idempotent — it returns early when anything already
# watches the event — so a re-run of `db:seed` cannot produce a second watcher
# and cannot undo an edit made at /triggers.
require Rails.root.join("db/migrate/20260821010100_seed_account_needs_reauth_trigger")
SeedAccountNeedsReauthTrigger.new.up
