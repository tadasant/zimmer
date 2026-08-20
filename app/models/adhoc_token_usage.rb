# frozen_string_literal: true

# One Anthropic API call made by Zimmer itself, outside any agent session.
#
# These are the calls the app makes on its own behalf: HeadlessInferenceService
# driving `claude -p` for session titles and push-notification summaries, and the
# CLI status probe. They are small next to session spend but invisible in the
# session table by construction, and they are the population most likely to
# contain a bug that quietly bills forever — a health check that turned out to be
# a full agent turn is exactly the shape of thing this table exists to surface.
class AdhocTokenUsage < ApplicationRecord
  include TokenAccounting

  # Where the call came from. `unknown` is deliberately a real value rather than
  # nil: a transcript that lands outside every known path pattern is a fact worth
  # showing, not a gap to hide.
  #
  # `headless_inference` covers both HeadlessInferenceService call sites — session
  # titles and push-notification summaries. The transcript does not record which
  # one ran, so they share one honest label instead of one of them being guessed.
  SOURCES = %w[headless_inference cli_status_probe unknown].freeze

  validates :source, presence: true, inclusion: { in: SOURCES }

  scope :for_source, ->(source) { where(source: source) }

  # The session the call was ABOUT (titling session N), not the session that made
  # it — there isn't one. Provenance, not ownership, so no foreign key.
  belongs_to :subject_session, class_name: "Session", optional: true,
    foreign_key: :subject_session_id, inverse_of: false
end
