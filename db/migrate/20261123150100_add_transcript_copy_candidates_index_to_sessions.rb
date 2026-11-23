# frozen_string_literal: true

# TranscriptCopyJob's candidate scan, which the health page also counts: archived sessions
# that hold a transcript, oldest archive first.
class AddTranscriptCopyCandidatesIndexToSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :sessions, [ :archived_at, :id ],
      name: "index_sessions_on_transcript_copy_candidates",
      where: "archived_at IS NOT NULL AND transcript_byte_size > 0",
      algorithm: :concurrently
  end
end
