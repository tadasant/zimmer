class CreateSubagentTranscripts < ActiveRecord::Migration[8.0]
  def change
    create_table :subagent_transcripts do |t|
      t.references :session, null: false, foreign_key: true
      t.string :agent_id, null: false
      t.text :transcript
      t.string :filename
      t.integer :message_count, default: 0
      t.timestamps
    end

    add_index :subagent_transcripts, [ :session_id, :agent_id ], unique: true
  end
end
