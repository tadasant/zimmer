# The named human beings this deployment knows about, moved out of
# `config/human_identities.yml` and into a table.
#
# The admin row is inserted here rather than left to `db/seeds.rb` because an
# existing deployment never runs seeds: the image entrypoint runs `db:prepare`,
# which seeds only a database it just created. Without this insert, the first
# deploy after this migration would come up with an empty roster — every
# HumanMessage write rejected for an unknown author, and no admin for the web
# UI. Raw SQL keeps the insert self-contained, so a replay years from now does
# not depend on what app/models/user.rb looks like then.
#
# `email` and `slack_user_ids` stay EMPTY here on purpose: this repository is
# public, and both are deployment configuration, not application source. They —
# and any further humans — are filled in per deployment at /supervisor/users.
class CreateUsers < ActiveRecord::Migration[8.0]
  def up
    create_table :users do |t|
      # The stable identity key. This is what HumanMessage#author has stored
      # since the records began, so it must not be renamed casually — see the
      # comment on User.
      t.string :key, null: false
      t.string :display_name, null: false
      t.string :email
      t.string :slack_user_ids, array: true, null: false, default: []
      # Free-form context about this human, injected into the human-messages
      # block Zimmer builds for every agent turn.
      t.text :notes

      t.timestamps
    end

    add_index :users, :key, unique: true
    add_index :users, "lower(email)", unique: true, where: "email IS NOT NULL",
              name: "index_users_on_lower_email"
    add_index :users, :slack_user_ids, using: :gin

    seed_rows
  end

  def down
    drop_table :users
  end

  private

  def seed_rows
    now = Time.current

    rows = [
      {
        key: "tadasant",
        display_name: "Tadas",
        notes: "Owns and operates this Zimmer deployment, and is its admin: " \
               "anything typed into the Zimmer web UI is his. When his instruction " \
               "conflicts with an inference you drew, his instruction wins."
      }
    ]

    rows.each do |row|
      execute <<~SQL.squish
        INSERT INTO users (key, display_name, email, slack_user_ids, notes, created_at, updated_at)
        VALUES (
          #{connection.quote(row[:key])},
          #{connection.quote(row[:display_name])},
          #{connection.quote(row[:email])},
          '{}',
          #{connection.quote(row[:notes])},
          #{connection.quote(now)},
          #{connection.quote(now)}
        )
        ON CONFLICT (key) DO NOTHING
      SQL
    end
  end
end
