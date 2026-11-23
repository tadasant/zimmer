# frozen_string_literal: true

# Moves the transcripts of long-archived sessions out of Postgres.
#
# WHY THIS EXISTS
#
# `session_transcript_chunks` was the one table in the schema with no retention at all.
# Its rows went away only through the ON DELETE CASCADE from `sessions`, and nothing
# deletes sessions, so every transcript Zimmer ever recorded stayed in the database for
# good. On production that took the managed cluster from ~32 GB of live data to close
# to its 60 GiB disk in about two months, and the storage had to be raised by hand
# (https://zimmer.tadasant.com/sessions/30528).
#
# WHAT IT DOES
#
# For each session archived more than `retention_days` ago that still holds chunks,
# oldest archive first:
#
#   1. Reassemble the transcript from its chunks and check it against the row's own
#      `transcript_byte_size` and `transcript_digest`. A session whose chunks disagree
#      with its row is skipped and counted, never offloaded.
#   2. Write it to TranscriptOffloadStore, which re-reads the file and checks the
#      digest again before it returns.
#   3. In one transaction, with the session row locked: re-check that the session is
#      still archived, is not being unarchived right now (Session.reap_protected?),
#      and its transcript is still the one just written, then delete the chunks and
#      stamp `transcript_offloaded_at`.
#
# Chunk rows are deleted only in step 3, and only after step 2 has proven the copy.
# Anything that fails before then leaves the chunks exactly as they were, and the
# next tick tries again.
#
# The stamp is written with `update_all`, so `sessions.updated_at` does not move.
# TranscriptArchiveJob decides what to rebuild by that column; bumping it here would
# make it re-archive every offloaded session once for no change in content.
#
# Nothing is lost to a reader. `Session#transcript` reads an offloaded transcript back
# from the store (ChunkedTranscript), the row's counters answer every size and
# freshness question without it, and unarchiving a session moves its transcript back
# into the chunk table before the session resumes.
#
# DISK
#
# Postgres does not give deleted rows' space back to the filesystem; it marks it
# reusable. So this stops the table growing — new transcripts fill the space old
# ones left — rather than shrinking the files already allocated. Giving that space
# back needs `pg_repack` or `VACUUM FULL`, the same one-time reclamation
# LogRetentionJob's header describes for `logs`.
#
# PACING
#
# A singleton on `maintenance`, bounded by SLICE_BUDGET per tick, so a backlog of
# tens of gigabytes drains over many ticks instead of in one long transaction. One
# transcript is resident at a time.
class TranscriptRetentionJob < ApplicationJob
  include DatabaseRetry
  include SingletonSweep

  queue_as :maintenance

  # Days after archiving before a session's transcript leaves Postgres. Long enough
  # that a session someone is likely to come back to is still in the database —
  # trash retention (Session::TRASH_RETENTION_PERIOD) is four days — and short enough
  # that the chunk table holds roughly a month of conversation rather than all of it.
  # Override with TRANSCRIPT_RETENTION_DAYS; a value below 1 is floored at 1.
  DEFAULT_RETENTION_DAYS = 30
  RETENTION_DAYS_ENV = "TRANSCRIPT_RETENTION_DAYS"

  # How long one tick may work, checked between sessions.
  SLICE_BUDGET = 3.minutes

  # The job stops while the volume holding the store has less than this free. Moving
  # data off the database's disk must not be what fills the host's: that volume also
  # holds every clone. Override with TRANSCRIPT_OFFLOAD_MINIMUM_FREE_BYTES.
  MINIMUM_FREE_BYTES = Integer(ENV.fetch("TRANSCRIPT_OFFLOAD_MINIMUM_FREE_BYTES", 20.gigabytes.to_s))

  # Candidate ids fetched per query.
  BATCH_SIZE = 100

  def self.retention_days
    configured = ENV[RETENTION_DAYS_ENV].presence&.to_i
    [ configured || DEFAULT_RETENTION_DAYS, 1 ].max
  end

  # Where a session whose chunks disagree with its own row records the digest it
  # was skipped at, so the job stops re-reading it every tick. Keyed on the digest
  # rather than a flag: a session that is later rewritten has a new digest and
  # becomes a candidate again by itself.
  SKIPPED_DIGEST_KEY = "transcript_offload_skipped_digest"

  # Raised from inside the streamed write when the chunks do not add up to what the
  # row says; it aborts the write, and the temp file goes with it.
  class ChunkMismatch < StandardError; end

  # A chunk disappeared mid-read: a concurrent rewrite, not corruption. Never marked.
  class ChunksMoved < StandardError; end

  # A tick ends after this many failures in a row: the store is broken, not a session.
  MAX_CONSECUTIVE_FAILURES = 3

  # Archived long enough ago, still holding chunks, and not already skipped at this
  # digest. The partial index `index_sessions_on_transcript_offload_candidates`
  # narrows it to archived rows still holding chunks; `status` and the skip marker
  # are filtered from the heap rows that index finds.
  def self.candidates(now: Time.current)
    Session.archived
      .where(transcript_offloaded_at: nil)
      .where("sessions.transcript_byte_size > 0")
      .where.not(transcript_digest: nil)
      .where(archived_at: ...(now - retention_days.days))
      .where("(sessions.metadata ->> '#{SKIPPED_DIGEST_KEY}') IS DISTINCT FROM sessions.transcript_digest")
  end

  # Sessions set aside because their chunks disagree with their row.
  def self.skipped_for_mismatch
    Session.archived.where(transcript_offloaded_at: nil)
      .where("sessions.transcript_byte_size > 0 AND sessions.archived_at IS NOT NULL")
      .where("(sessions.metadata ->> '#{SKIPPED_DIGEST_KEY}') = sessions.transcript_digest")
  end

  def perform(budget: SLICE_BUDGET, now: Time.current)
    deadline = monotonic_now + budget.to_f
    result = { offloaded: 0, skipped: 0, failed: 0, bytes: 0 }
    after = [ Time.at(0), 0 ]

    failures = 0
    TranscriptOffloadStore.prepare!
    swept = TranscriptOffloadStore.sweep_orphaned_temps
    Rails.logger.warn("[TranscriptRetentionJob] swept #{swept} orphaned temp file(s)") if swept.positive?
    loop do
      return finish(result) unless room_to_offload?

      batch = with_db_retry do
        self.class.candidates(now: now)
          .where("(sessions.archived_at, sessions.id) > (?, ?)", *after)
          .order(:archived_at, :id)
          .limit(BATCH_SIZE)
          .pluck(:archived_at, :id)
      end
      break if batch.empty?

      batch.each do |archived_at, id|
        return finish(result) if monotonic_now >= deadline

        after = [ archived_at, id ]
        outcome, bytes = offload(id, now: now)
        result[outcome] += 1
        result[:bytes] += bytes.to_i
        failures = outcome == :failed ? failures + 1 : 0
        return finish(result) if failures >= MAX_CONSECUTIVE_FAILURES
      end
    end

    finish(result)
  rescue TranscriptOffloadStore::Error => e
    # The store will not act for this process at all; nothing was read or deleted.
    Rails.logger.error("[TranscriptRetentionJob] #{e.class}: #{e.message}")
    finish(result)
  end

  private

  # Unknown free space is not a reason to stop: `df` failing says nothing about the
  # disk, and a write that hits ENOSPC fails before any chunk is deleted.
  def room_to_offload?
    free = CloneDiskGuard.available_bytes(TranscriptOffloadStore.root)
    return true if free.nil? || free >= MINIMUM_FREE_BYTES

    Rails.logger.warn("[TranscriptRetentionJob] not offloading: #{free} bytes free, under the #{MINIMUM_FREE_BYTES} byte floor")
    false
  end

  def finish(result)
    # WARN, because production ships only WARN and above to the log store, and this
    # line is how a drain's progress is visible there. A tick with nothing to do
    # logs nothing.
    if result.values_at(:offloaded, :skipped, :failed).any?(&:positive?)
      Rails.logger.warn(
        "[TranscriptRetentionJob] offloaded #{result[:offloaded]} transcript(s), #{result[:bytes]} bytes; " \
        "skipped #{result[:skipped]}, failed #{result[:failed]}"
      )
    end
    result
  end

  # Returns [:offloaded | :skipped | :failed, bytes moved].
  def offload(session_id, now:)
    row = with_db_retry do
      Session.where(id: session_id)
        .pick(:status, :archived_at, :transcript_offloaded_at, :transcript_byte_size, :transcript_digest)
    end
    return [ :skipped, 0 ] unless row

    status, archived_at, offloaded_at, byte_size, digest = row
    return [ :skipped, 0 ] unless eligible?(status, archived_at, offloaded_at, byte_size, now)

    return [ :skipped, 0 ] if digest.blank?

    begin
      stream_chunks_to_store(session_id, byte_size, digest)
    rescue ChunkMismatch => e
      Rails.logger.warn("[TranscriptRetentionJob] session #{session_id}: #{e.message}; not offloading, and not retrying at this digest")
      with_db_retry do
        Session.where(id: session_id, transcript_digest: digest, transcript_offloaded_at: nil).update_all(
          [ "metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)", SKIPPED_DIGEST_KEY, digest ]
        )
      end
      return [ :skipped, 0 ]
    rescue ChunksMoved
      return [ :skipped, 0 ]
    end

    committed = with_db_retry do
      Session.transaction do
        locked = Session.lock.where(id: session_id)
          .pick(:status, :archived_at, :transcript_offloaded_at, :transcript_byte_size, :transcript_digest)
        # Destroyed while it was being copied: its cleanup ran before this file existed.
        TranscriptOffloadStore.delete(session_id) if locked.nil?
        current_status, current_archived_at, current_offloaded_at, current_size, current_digest = locked

        if locked && eligible?(current_status, current_archived_at, current_offloaded_at, current_size, now) &&
           current_size == byte_size && current_digest == digest &&
           !Session.reap_protected?(session_id)
          SessionTranscriptChunk.where(session_id: session_id).delete_all
          Session.where(id: session_id).update_all(transcript_offloaded_at: Time.current)
          true
        else
          false
        end
      end
    end

    committed ? [ :offloaded, byte_size ] : [ :skipped, 0 ]
  rescue TranscriptOffloadStore::Error, SystemCallError => e
    Rails.logger.error("[TranscriptRetentionJob] session #{session_id}: #{e.class}: #{e.message}")
    [ :failed, 0 ]
  end

  # Copies the chunks into the store one at a time, hashing as it goes, so one
  # transcript costs about one chunk of memory rather than three copies of itself.
  # The store then re-reads the file and checks the digest on what is on disk.
  def stream_chunks_to_store(session_id, byte_size, digest)
    seqs = with_db_retry { SessionTranscriptChunk.where(session_id: session_id).order(:seq).pluck(:seq) }

    TranscriptOffloadStore.write_stream(session_id, digest: digest) do |out|
      sha = Digest::SHA256.new
      bytes = 0
      seqs.each do |seq|
        content = with_db_retry do
          SessionTranscriptChunk.uncached { SessionTranscriptChunk.where(session_id: session_id, seq: seq).pick(:content) }
        end
        raise ChunksMoved if content.nil?

        sha.update(content)
        bytes += content.bytesize
        out.write(content)
      end

      unless bytes == byte_size && sha.hexdigest == digest
        raise ChunkMismatch, "chunks (#{bytes} bytes) do not match the row (#{byte_size} bytes, digest #{digest})"
      end
    end
  end

  def eligible?(status, archived_at, offloaded_at, byte_size, now)
    status.to_s == "archived" && offloaded_at.nil? && byte_size.to_i.positive? &&
      archived_at.present? && archived_at < now - self.class.retention_days.days
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
