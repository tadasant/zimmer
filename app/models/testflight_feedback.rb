# frozen_string_literal: true

# One TestFlight feedback submission from the Zimmer iOS app, pulled from App
# Store Connect by TestflightFeedbackPollJob.
#
#   crash      → a `betaFeedbackCrashSubmissions` record: the tester's comment,
#                the device, and `crash_log` — the whole crash report as App
#                Store Connect returns it, which is what makes a crash in the
#                car readable after the fact.
#   screenshot → a `betaFeedbackScreenshotSubmissions` record: the comment and
#                the screenshot metadata (in `raw_attributes`). The image URLs App
#                Store Connect hands out expire, so the row keeps what they were
#                rather than the images.
#
# `asc_id` is App Store Connect's id for the submission and the dedupe key: the
# poller inserts a submission once and never rewrites it, apart from filling in
# a crash log it could not fetch the first time.
#
# Read by agents through the `get_testflight_crashes` MCP tool, and by a human
# at /supervisor/testflight_feedbacks.
class TestflightFeedback < ApplicationRecord
  KINDS = %w[crash screenshot].freeze

  validates :asc_id, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  scope :crashes, -> { where(kind: "crash") }
  scope :newest_first, -> { order(Arel.sql("submitted_at DESC NULLS LAST"), id: :desc) }
  # A crash whose log App Store Connect has not given us yet, and is recent
  # enough to keep asking for. Past the window a log that never arrived is not
  # going to, and asking forever would spend a request per row per tick.
  scope :awaiting_crash_log, ->(since:) { crashes.where(crash_log: nil).where(created_at: since..) }

  # The lines of a crash report a person reads first, in the order they appear.
  # Apple's `.crash` text format; anything else simply yields fewer lines.
  HEADLINE_PREFIXES = [ "Exception Type:", "Exception Codes:", "Termination Reason:", "Crashed Thread:" ].freeze

  def crash? = kind == "crash"

  def headline
    return nil if crash_log.blank?

    crash_log.each_line.map(&:strip).select { |line| HEADLINE_PREFIXES.any? { |prefix| line.start_with?(prefix) } }
      .first(HEADLINE_PREFIXES.size).join(" · ").presence
  end
end
