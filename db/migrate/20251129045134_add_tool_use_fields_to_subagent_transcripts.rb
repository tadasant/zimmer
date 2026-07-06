class AddToolUseFieldsToSubagentTranscripts < ActiveRecord::Migration[8.0]
  def change
    add_column :subagent_transcripts, :tool_use_id, :string
    add_column :subagent_transcripts, :subagent_type, :string
    add_column :subagent_transcripts, :description, :string
    add_column :subagent_transcripts, :status, :string, default: "running"
    add_column :subagent_transcripts, :duration_ms, :integer
    add_column :subagent_transcripts, :total_tokens, :integer
    add_column :subagent_transcripts, :tool_use_count, :integer

    add_index :subagent_transcripts, :tool_use_id
  end
end
