class CreateTestflightFeedbacks < ActiveRecord::Migration[8.1]
  # What TestFlight testers sent from the Zimmer iOS app, pulled from App Store
  # Connect by TestflightFeedbackPollJob: crash submissions with their full crash
  # log, and screenshot submissions. One row per App Store Connect submission;
  # `asc_id` is that submission's id and the poller's dedupe key.
  def change
    create_table :testflight_feedbacks do |t|
      t.string :asc_id, null: false
      t.string :kind, null: false
      t.datetime :submitted_at
      t.string :build_number
      t.string :device_model
      t.string :os_version
      t.text :comment
      t.string :tester_email
      # The crash log's own text, exactly as App Store Connect returns it. Null
      # until it has been fetched; the poller retries a missing one on later ticks.
      t.text :crash_log
      t.datetime :crash_log_fetched_at
      # Every attribute App Store Connect returned for the submission, so a field
      # without a column of its own is still readable.
      t.jsonb :raw_attributes, null: false, default: {}
      t.timestamps
    end

    add_index :testflight_feedbacks, :asc_id, unique: true
    add_index :testflight_feedbacks, [ :kind, :submitted_at ]
  end
end
