class AddCarplayFitToSessions < ActiveRecord::Migration[8.1]
  # CarPlay fit — whether the next thing this session needs from a human can be
  # done by voice from a car, or needs a laptop. A derived judgement with an
  # explicit override, not a tag: it carries a reason, who wrote it, when, and the
  # transcript position it was written against, which is what makes it go stale
  # the moment the session says something new. See SessionCarplayFit.
  #
  # Presentation and triage only. Nothing in the scheduler, the spot queue, the
  # quota gate or the state machine reads any of these columns — the same
  # contract `visibility` has.
  def change
    add_column :sessions, :carplay_fit, :string
    add_column :sessions, :carplay_fit_reason, :string
    add_column :sessions, :carplay_fit_source, :string
    add_column :sessions, :carplay_fit_set_at, :datetime
    add_column :sessions, :carplay_fit_line_count, :integer

    # Only marked rows are ever looked up by this column; the filters that read
    # it run inside a status-narrowed listing, so a partial index is enough.
    add_index :sessions, :carplay_fit, where: "carplay_fit IS NOT NULL"
  end
end
