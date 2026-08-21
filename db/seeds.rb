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
#
# Two guards on the coupling, because `db:seed` runs from the image entrypoint and
# must not be the thing that stops a container booting:
#
#   * `defined?` first. ActiveRecord `load`s migration files, which does not
#     populate `$LOADED_FEATURES`, so a `db:prepare` that migrates and seeds in one
#     process would otherwise re-execute this file and warn on every constant.
#   * `LoadError` is survivable. If the migration is ever squashed or pruned, a
#     fresh install should come up without this trigger and say so, not fail to boot.
begin
  unless defined?(SeedAccountNeedsReauthTrigger)
    require Rails.root.join("db/migrate/20260821010100_seed_account_needs_reauth_trigger").to_s
  end

  SeedAccountNeedsReauthTrigger.new.up
rescue LoadError => e
  Rails.logger.warn(
    "[seeds] Could not seed the account_needs_reauth trigger (#{e.class}: #{e.message}). " \
    "Create it by hand at /triggers, or nothing will report a dead runtime account."
  )
end
