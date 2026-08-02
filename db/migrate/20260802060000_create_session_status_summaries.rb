class CreateSessionStatusSummaries < ActiveRecord::Migration[8.0]
  def change
    create_table :session_status_summaries do |t|
      t.references :session, null: false, index: { unique: true },
                   foreign_key: { on_delete: :cascade }
      t.text :summary
      t.datetime :generated_at

      # Transcript line count at the moment the summary that is currently
      # displayed was generated. "Messages since summary generated" is the
      # difference between this and the session's live line count, so it is the
      # whole staleness mechanism — it must only advance on a SUCCESSFUL
      # generation, never when one is merely requested.
      t.integer :transcript_line_count, null: false, default: 0

      # Line count captured when the in-flight generation was requested. The
      # fork reads the transcript as of that moment, so this — not the count at
      # harvest time — is what becomes transcript_line_count on success.
      t.integer :requested_line_count
      t.datetime :requested_at

      # idle → pending → ready | failed
      t.string :state, null: false, default: "idle"
      t.text :error

      # The fork whose agent turn is (or was) producing the summary. Nullified
      # rather than cascaded: losing the fork must not lose the summary text.
      t.references :fork_session, null: true, index: true,
                   foreign_key: { to_table: :sessions, on_delete: :nullify }

      t.timestamps
    end
  end
end
