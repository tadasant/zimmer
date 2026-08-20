# frozen_string_literal: true

# Clears the Status blurbs that are actually the runtime refusing to work.
#
# SessionStatusSummaryHarvestJob treated any pause of a summary fork as a
# finished turn. AuthOutageParkService parks a session by letting it reach
# `pause!`, so a fork that ran out of login pool was harvested as if it had
# answered — and the last assistant text in its transcript was the runtime's own
# refusal. Those rows were then stamped `ready` at the requested line count,
# which is to say marked CURRENT, so `SessionStatusSummary#stale?` is false and
# no future generation will replace them. 73 sessions in this deployment were
# displaying one when this was written, two of them sitting in the user's action
# queue showing "You've hit your session limit · resets 10pm (UTC)" as their
# status.
#
# The harvest job now refuses these on the way in. This clears the population
# already stored, which is the part no sweep would otherwise reach: nulling the
# text and the line count is what makes them stale again, and therefore what
# makes StatusSummaryBackstopJob eligible to write a real summary over them.
#
# Irreversible: the rows held a refusal string and nothing else, so there is no
# prior state worth restoring — `down` would have to re-insert text that was
# never a summary in the first place.
class ClearStatusSummariesThatAreRuntimeRefusals < ActiveRecord::Migration[8.0]
  # The same two wordings SessionStatusSummaryHarvestJob::REFUSAL_PATTERNS is
  # built from, as POSIX regular expressions. Spelled out here rather than
  # interpolated from the Ruby constants because a migration has to keep meaning
  # what it meant when it ran, and those constants will follow the CLI's wording
  # as it moves.
  REFUSAL_REGEXES = [
    "hit your.*limit.*resets",
    "not logged in|please run /login"
  ].freeze

  # Matches the same shape the job's #refused_answer? requires: a single short
  # line, so a genuine summary that discusses a session hitting a limit is left
  # alone.
  MAX_REFUSAL_CHARS = 200

  def up
    REFUSAL_REGEXES.each do |regex|
      execute(<<~SQL.squish)
        UPDATE session_status_summaries
        SET summary = NULL,
            generated_at = NULL,
            transcript_line_count = 0,
            state = 'failed',
            error = 'The summary fork was parked before it could answer, and the runtime''s refusal was stored as the summary. Cleared; a new one is generated automatically.',
            updated_at = NOW()
        WHERE summary IS NOT NULL
          AND length(summary) <= #{MAX_REFUSAL_CHARS}
          AND position(chr(10) in summary) = 0
          AND summary ~* #{connection.quote(regex)}
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
