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
