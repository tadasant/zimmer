# frozen_string_literal: true

# Moves every transcript still living in `sessions.transcript` into
# `session_transcript_chunks`, then empties that column (#110).
#
# WHY THIS IS A TASK AND NOT PART OF THE MIGRATION: it rewrites every session row
# that has ever held a conversation — thousands of them, several gigabytes of
# TOASTed text (staging measured 5,038 MB compressed across 5,096 sessions in
# #495). Doing that inside a migration would hold the deploy open for as long as it
# takes and would materialise transcripts faster than it can free them. As a
# post-deploy task it is sliced by `sweep`, resumes from its cursor on the next
# tick, and answers for itself in `post_deploy_task_runs` — on /health, in
# `GET /api/v1/health`, from `get_system_health`, at
# /supervisor/post_deploy_task_runs.
#
# **PHASE 2 MUST NOT DROP `sessions.transcript` UNTIL THIS RUN READS `succeeded`
# THERE *AND* `verification_failures` IS ZERO.** `succeeded` on its own is not the
# gate, and the difference is the whole safety property: a row this task could not
# copy keeps its column and is skipped, `sweep` never revisits it, and the run
# still finishes clean. So the failing rows are named individually in
# `unmigrated_session_ids` — a bounded list on the same panel — and phase 2 has to
# see that empty, not merely see this green.
#
# NOTHING IS WAITING ON IT. `Session#transcript` reads the legacy column for any
# row this has not reached yet, so the system is whole from the moment the deploy
# lands and gets cheaper as the task walks the table. That is deliberate: a read
# path that is correct only after a backfill finishes is a half-migrated read path.
#
# THE COPY IS VERIFIED, NOT ASSUMED. Per row, in one transaction: write the chunks,
# read them back, and require the concatenation to equal the source byte for byte
# (and, for the legacy Array format, to re-parse to the same events) before the
# column is cleared. A row that fails verification keeps its chunks deleted and its
# column intact — it goes on reading from the legacy column exactly as before — and
# is counted in `verification_failures` for a human to look at. The alternative,
# clearing first and trusting the write, is how a backfill turns into data loss.
#
# IDEMPOTENT AND TERMINATING: every row it touches ends with `transcript` NULL, so
# it drops out of the relation and a second run finds nothing. The predicate is
# served by `index_sessions_on_id_where_transcript_present`, so the closing query —
# the one proving there is nothing left — is an index scan rather than a sequential
# scan over gigabytes of TOAST.
class BackfillSessionTranscriptChunks < PostDeployTask
  BATCH_SIZE = 200

  # How many failing session ids to carry on the ledger row. A cap, because `stats`
  # is rendered verbatim on the health panel; the count is exact either way.
  MAX_REPORTED_IDS = 50

  def up
    # Read the counters back out of the ledger before the first batch, so a slice
    # resumed after the budget ran out carries on from the totals it recorded
    # rather than restarting them at zero.
    @migrated = stats.fetch("migrated", 0)
    @already_chunked = stats.fetch("already_chunked", 0)
    @failures = stats.fetch("verification_failures", 0)
    @unmigrated = stats.fetch("unmigrated_session_ids", [])
    record_progress!

    # `select(:id)` rather than whole rows: a bare batch would instantiate 200
    # transcripts at once, which is the OOM this task exists to make less likely
    # (#495), not one to reproduce.
    sweep(Session.select(:id).where.not(transcript: nil), batch_size: BATCH_SIZE) do |batch|
      batch.each { |row| migrate_one(row.id) }
      record_progress!
    end
  end

  private

  def record_progress!
    checkpoint!(
      migrated: @migrated,
      already_chunked: @already_chunked,
      verification_failures: @failures,
      unmigrated_session_ids: @unmigrated
    )
  end

  # A row that did not migrate keeps its legacy column and goes on reading from it,
  # so nothing is broken — but it is the one thing phase 2 must not step on, and a
  # bare count would leave whoever checks with no way to find it without a shell.
  def record_failure!(session_id)
    @failures += 1
    @unmigrated << session_id if @unmigrated.size < MAX_REPORTED_IDS
  end

  def migrate_one(session_id)
    Session.transaction do
      # `lock`, because a live session is being polled every few seconds and the
      # poller writes chunks through the model. Without the row lock this could
      # read the legacy column, write chunks the poller has just superseded, and
      # then clear the column — losing whatever the poll added in between.
      session = Session.lock.select(:id, :transcript, :transcript_byte_size).find_by(id: session_id)
      next if session.nil?

      legacy = session.read_attribute(:transcript)
      next if legacy.nil?

      # Already migrated by an ordinary write since the deploy: the chunk set is
      # authoritative and the column is just the stale copy left behind. Nothing to
      # copy, only something to free.
      if session.read_attribute(:transcript_byte_size).to_i.positive?
        Session.where(id: session_id).update_all(transcript: nil)
        @already_chunked += 1
        next
      end

      content = Session.normalize_transcript(legacy)

      if content.nil?
        # `[]` or `""` — present enough for `IS NOT NULL` and empty as a transcript.
        Session.where(id: session_id).update_all(transcript: nil)
        @migrated += 1
        next
      end

      SessionTranscriptChunk.where(session_id: session_id).delete_all
      rows = SessionTranscriptChunk.rows_for(session_id: session_id, content: content)
      SessionTranscriptChunk.insert_all!(rows) if rows.any?

      unless verified?(session_id: session_id, content: content, legacy: legacy)
        SessionTranscriptChunk.where(session_id: session_id).delete_all
        record_failure!(session_id)
        next
      end

      # `update_all`: no callbacks (the chunks are already written), and — the one
      # that matters — no `updated_at` bump. Touching `updated_at` on every session
      # that ever had a transcript would reorder every list in the UI and re-archive
      # the entire corpus in `TranscriptArchiveJob`, for a write nobody can see.
      Session.where(id: session_id).update_all(
        transcript: nil,
        transcript_byte_size: content.bytesize,
        transcript_line_count: Session.transcript_line_count(content),
        transcript_digest: Digest::SHA256.hexdigest(content)
      )
      @migrated += 1
    end
  rescue StandardError => e
    # One unreadable row must not stop the sweep: the column is untouched, so that
    # session keeps rendering from it, and the counter says how many need a look.
    record_failure!(session_id)
    logger.error("[BackfillSessionTranscriptChunks] session #{session_id}: #{e.class}: #{e.message}")
    ErrorReporter.report_exception(e, context: { session_id: session_id, task: self.class.name })
  end

  # Byte-for-byte, plus event-for-event when the source was the legacy Array format
  # (where "identical" cannot mean "identical bytes" — there were no bytes, only
  # parsed events, and the encoding is what is being checked).
  def verified?(session_id:, content:, legacy:)
    reassembled = SessionTranscriptChunk.where(session_id: session_id).order(:seq).pluck(:content).join
    return false unless reassembled == content

    return true unless legacy.is_a?(Array)

    reassembled.lines.map { |line| JSON.parse(line) } == legacy
  rescue JSON::ParserError
    false
  end
end
