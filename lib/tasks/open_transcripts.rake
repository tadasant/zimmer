# frozen_string_literal: true

namespace :open_transcripts do
  desc "Fail when the vendored OpenTranscripts snapshot has drifted from upstream"
  # No `=> :environment` on purpose: the script is stdlib-only and booting Rails
  # (and its database connection) to hash five files would be pure cost. The
  # scheduled workflow runs the script directly for the same reason; this task is
  # the discoverable local entry point.
  task :check_drift do
    script = File.expand_path("../../scripts/check_open_transcripts_drift.rb", __dir__)
    abort "Drift check failed" unless system(RbConfig.ruby, script)
  end

  desc "Redact secrets from transcripts already stored in the database (DRY_RUN=1 to preview)"
  # Redaction happens on write, at TranscriptSource#read, so everything captured
  # from the day it shipped is already clean. Rows written before that are not,
  # and no read path will clean them. This rewrites them in place.
  #
  # It is irreversible by design — that is the whole point — so it previews by
  # default and only writes when asked.
  task redact_stored: :environment do
    dry_run = ENV["DRY_RUN"].blank? || ENV["DRY_RUN"] != "0"
    puts dry_run ? "DRY RUN — nothing will be written. Re-run with DRY_RUN=0 to apply." : "Applying redaction to stored transcripts."

    # Counts markers rather than diffing, so the report never has to hold the
    # secret the rewrite just removed.
    added_markers = ->(before, after) { after.scan(/\[REDACTED:/).length - before.scan(/\[REDACTED:/).length }

    changed_sessions = 0
    Session.where.not(transcript: [ nil, "" ]).find_each(batch_size: 50) do |session|
      redacted = TranscriptRedactor.redact(session.transcript)
      next if redacted == session.transcript

      changed_sessions += 1
      puts "  session ##{session.id}: #{added_markers.call(session.transcript, redacted)} redaction(s)"
      session.update_columns(transcript: redacted) unless dry_run
    end

    changed_subagents = 0
    SubagentTranscript.where.not(transcript: [ nil, "" ]).find_each(batch_size: 50) do |subagent|
      redacted = TranscriptRedactor.redact(subagent.transcript)
      next if redacted == subagent.transcript

      changed_subagents += 1
      puts "  subagent transcript ##{subagent.id}: #{added_markers.call(subagent.transcript, redacted)} redaction(s)"
      subagent.update_columns(transcript: redacted) unless dry_run
    end

    puts
    puts "#{changed_sessions} session transcript(s) and #{changed_subagents} subagent transcript(s) " \
         "#{dry_run ? 'would be' : 'were'} rewritten."
  end
end
