# frozen_string_literal: true

# Signed human merge approvals, on both sides of the wire.
#
# One table for both directions because the two rows are the same fact seen
# from two deployments: the issuer records the approval it signed, the receiver
# records the approval it verified and acted on. Each side keeps its own copy,
# so an audit on either needs nothing from the other. See MergeAttestation.
class CreateMergeAttestations < ActiveRecord::Migration[8.1]
  def change
    create_table :merge_attestations do |t|
      t.string :direction, null: false
      t.string :jti, null: false
      t.string :issuer, null: false
      t.string :audience, null: false
      t.string :key_id, null: false
      t.string :pr_url, null: false
      t.string :repo, null: false
      t.integer :pr_number, null: false
      t.string :head_sha, null: false
      t.string :approver, null: false
      t.string :approver_name
      t.string :channel, null: false
      t.string :surface
      t.text :read_back, null: false
      t.text :answer, null: false
      t.datetime :approved_at, null: false
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.references :session, foreign_key: { on_delete: :nullify }
      t.references :human_message, foreign_key: { on_delete: :nullify }
      t.string :remote_server
      t.string :remote_session_url
      t.string :outcome
      t.text :outcome_detail
      t.jsonb :claims, null: false, default: {}
      t.timestamps
    end

    # Single use is this index. A receiver claims a jti by inserting it, so a
    # replayed token loses the race to the row its first use wrote.
    add_index :merge_attestations, %i[direction issuer jti], unique: true
    add_index :merge_attestations, :pr_url
  end
end
