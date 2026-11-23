# frozen_string_literal: true

# One row per verified copy of a session's transcript in object storage: where each
# object is, and what it holds. See TranscriptCopyJob.
#
# No foreign key to sessions, and no cascade: the copy outlives the session, so deleting
# a session must not delete the only record of where its copy is.
class CreateTranscriptCopies < ActiveRecord::Migration[8.1]
  def change
    create_table :transcript_copies do |t|
      t.bigint :session_id, null: false
      t.string :bucket, null: false
      t.string :manifest_object, null: false
      t.bigint :manifest_generation, null: false
      t.string :transcript_object, null: false
      t.bigint :transcript_generation, null: false
      t.string :transcript_digest, null: false
      t.bigint :transcript_byte_size, null: false
      t.integer :transcript_line_count, null: false
      t.bigint :transcript_compressed_bytes, null: false
      # Human and assistant text alone, as a measure of what a searchable remainder costs.
      t.bigint :conversation_byte_size
      t.bigint :conversation_compressed_bytes
      t.jsonb :subagents, null: false, default: []
      t.string :subagents_fingerprint, null: false
      t.datetime :verified_at, null: false
      t.timestamps
    end

    add_index :transcript_copies, [ :session_id, :transcript_digest ]
    add_index :transcript_copies, [ :bucket, :manifest_object ], unique: true
    add_index :transcript_copies, [ :bucket, :verified_at ]
  end
end
