# frozen_string_literal: true

# `Session#transcript`, backed by an append-only chunk table instead of one column.
#
# WHAT THIS CHANGES AND WHAT IT DELIBERATELY DOES NOT
#
# The accessor keeps its old shape exactly: `session.transcript` returns the whole
# JSONL document as a String, `session.update!(transcript: content)` stores it, and
# every one of the ~50 call sites that does either keeps working untouched. What
# changes is underneath. A write whose value EXTENDS what is stored — which is what
# a transcript poll produces, every five seconds, for the life of a session — now
# writes only the bytes that are new, instead of re-TOASTing and re-WALing the
# entire accumulated conversation (#110).
#
# HOW AN EXTENSION IS RECOGNISED WITHOUT READING THE TRANSCRIPT BACK
#
# `sessions.transcript_digest` holds SHA-256 of the whole stored document and
# `sessions.transcript_byte_size` its length. An incoming value extends the stored
# one exactly when it is longer and its first `transcript_byte_size` bytes hash to
# `transcript_digest`. Both checks are passes over a value the caller already has in
# memory, so deciding "append or replace" costs no database read at all — the point
# being that the append path must not re-materialise the thing it is avoiding
# rewriting.
#
# WHY THE COUNTERS ARE COLUMNS RATHER THAN AGGREGATES
#
# Three reasons, and the third is the one that is easy to miss:
#   * `transcript_line_count` is what the regression guard compares. Computing it
#     used to detoast the whole document to count newlines; as a column it is free.
#   * A `SUM(line_count)` over the chunks would be a second query on a path that
#     runs on every poll.
#   * They are what keeps a transcript write DIRTYING THE SESSION ROW. The bytes
#     moved out of `sessions`, but `updated_at` moving when the conversation grows
#     is depended on by change detection (`TranscriptArchiveJob`) and by every
#     "when did this last do something" reader in the UI.
#
# THE PRE-BACKFILL FALLBACK
#
# `sessions.transcript` still exists and still holds every transcript written before
# this shipped — the column cannot be dropped in the same deploy that stops writing
# it (AGENTS.md, "Dropping a column takes two deploys"). So the reader prefers the
# chunk set when there is one (`transcript_byte_size` positive) and falls back to the
# legacy column otherwise. `BackfillSessionTranscriptChunks` empties that column row
# by row, after verifying each copy byte for byte; when it reads `succeeded` the
# fallback is dead code, and phase 2 removes it with the column.
#
# ON `transcript_regression?`
#
# It survives, and it has to. It is not an artifact of whole-column storage — it
# encodes a POLICY: a transcript file on disk that is shorter than what Zimmer has
# recorded means the clone was recreated and the runtime started a fresh file, not
# that the conversation got shorter. No storage layout can decide that; only the
# caller knows whether a shorter value is a truncation to refuse or a deliberate
# rewrite to honour (the recovery-segment merge in `TranscriptPollerService` is the
# latter). What the chunk store changes is the shape of the risk: a truncating write
# is now an explicit `delete_all` of a session's chunks, logged with the byte counts
# on both sides, rather than an UPDATE that looks exactly like every other one.
module ChunkedTranscript
  extend ActiveSupport::Concern

  included do
    # No `dependent:`. The foreign key is ON DELETE CASCADE, so the database already
    # guarantees a chunk cannot outlive its session, and a Rails-side sweep would
    # only duplicate that at the cost of a query per destroy — the same call the
    # `outcome_analyses` association makes.
    has_many :transcript_chunks,
      -> { order(:seq) },
      class_name: "SessionTranscriptChunk",
      inverse_of: :session

    after_save :flush_transcript_chunks
  end

  # The whole transcript, as the JSONL String every caller has always received.
  #
  # Pre-backfill rows can still hand back the legacy `json` column's value, which for
  # the oldest sessions is an Array rather than a String — that is why the Array
  # branches in `parsed_transcript` and friends are still there. Nothing WRITES an
  # Array any more: the setter normalises one to JSONL.
  def transcript
    return @staged_transcript if defined?(@staged_transcript)
    return @chunked_transcript_text if defined?(@chunked_transcript_text)
    return legacy_transcript_column unless chunked_transcript?

    @chunked_transcript_text = transcript_chunk_contents.join
  end

  def transcript=(value)
    normalized = self.class.normalize_transcript(value)

    @staged_transcript = normalized
    remove_instance_variable(:@chunked_transcript_text) if defined?(@chunked_transcript_text)

    self[:transcript_byte_size] = normalized.nil? ? 0 : normalized.bytesize
    self[:transcript_line_count] = self.class.transcript_line_count(normalized)
    self[:transcript_digest] = normalized.nil? ? nil : Digest::SHA256.hexdigest(normalized)
    # Only when the new value is empty. Otherwise the legacy column is left exactly
    # as it was — a rollback in the window before the backfill runs then still finds
    # the history it wrote — and `transcript_byte_size` is what says the chunks are
    # authoritative. Clearing it here is what keeps "written empty" from reading back
    # as "never migrated, here is the stale column".
    self[:transcript] = nil if normalized.nil? && has_attribute?(:transcript)

    value
  end

  # Line count of the stored transcript, without touching a byte of it.
  def transcript_line_count
    return self.class.transcript_line_count(@staged_transcript) if defined?(@staged_transcript)
    return self.class.transcript_line_count(legacy_transcript_column) unless chunked_transcript?

    read_attribute(:transcript_line_count).to_i
  end

  # Byte length of the stored transcript, without materialising it.
  #
  # The pre-backfill fallback is a presence-grade answer rather than an exact one:
  # a legacy Array transcript has no byte length until it is encoded, and measuring
  # `to_s` of one counts Ruby's inspect output. Blank is still blank, which is all
  # `transcript_present?` asks, and every row stops taking this branch the moment
  # the backfill reaches it.
  def transcript_byte_size
    return @staged_transcript.to_s.bytesize if defined?(@staged_transcript)

    unless chunked_transcript?
      legacy = legacy_transcript_column
      return legacy.blank? ? 0 : legacy.to_s.bytesize
    end

    read_attribute(:transcript_byte_size).to_i
  end

  # Whether this session has a transcript at all — the presence check, answered
  # from the row rather than by detoasting the conversation to ask if it is blank.
  def transcript_present?
    transcript_byte_size.positive?
  end

  # True when persisting +incoming+ over this session's stored transcript would drop
  # conversation events. The instance form of `Session.transcript_regression?`, and
  # the one to prefer: it reads the stored side's line count from the row instead of
  # loading the whole transcript to count newlines in it.
  def transcript_regression?(incoming)
    self.class.transcript_line_count(incoming) < transcript_line_count
  end

  def reload(*)
    remove_instance_variable(:@staged_transcript) if defined?(@staged_transcript)
    remove_instance_variable(:@chunked_transcript_text) if defined?(@chunked_transcript_text)
    super
  end

  class_methods do
    # Everything that reaches storage is JSONL text. The legacy Array format —
    # one parsed event per element, predating JSONL — is encoded rather than
    # rejected, because a handful of very old rows and a number of tests still
    # speak it. `JSON.generate` escapes newlines inside values, so one element
    # becomes exactly one line and the event count is preserved.
    def normalize_transcript(value)
      case value
      when nil then nil
      when Array then value.empty? ? nil : value.map { |event| JSON.generate(event) }.join("\n") + "\n"
      else value.to_s.presence
      end
    end
  end

  private

  # Whether the chunk table is the authority for this session. False only for a row
  # the backfill has not reached yet, whose transcript is still in the old column.
  def chunked_transcript?
    return false unless has_attribute?(:transcript_byte_size)

    read_attribute(:transcript_byte_size).to_i.positive?
  end

  # nil rather than raising on a partially-selected row: `StatusSummaryBackstopJob`
  # deliberately selects every column BUT this one, precisely to avoid loading it.
  def legacy_transcript_column
    return nil unless has_attribute?(:transcript)

    read_attribute(:transcript)
  end

  def transcript_chunk_contents
    return transcript_chunks.map(&:content) if transcript_chunks.loaded?

    SessionTranscriptChunk.where(session_id: id).order(:seq).pluck(:content)
  end

  # Writes the staged transcript into the chunk table. Runs inside the save's own
  # transaction, so the chunk set and the counters on the row commit together or
  # not at all.
  def flush_transcript_chunks
    return unless defined?(@staged_transcript)

    value = @staged_transcript
    base_bytes = attribute_before_last_save("transcript_byte_size").to_i
    base_digest = attribute_before_last_save("transcript_digest")
    # A row still on the legacy column has no chunks to extend, whatever the
    # counters say — they were both zero until this save.
    #
    # `base_is_chunked` also requires the chunk set to be exactly as long as the
    # counters claim, which is what makes an append safe against a writer working
    # from a stale read. Appending a delta computed against a base that is no
    # longer the tail would splice two views of the conversation together; the
    # aggregate is one index-backed sum over this session's rows, reads no
    # `content`, and turns that case into an ordinary replace instead.
    stored_bytes = SessionTranscriptChunk.where(session_id: id).sum(:byte_size)
    base_is_chunked = base_bytes.positive? && stored_bytes == base_bytes

    if value.nil?
      SessionTranscriptChunk.where(session_id: id).delete_all if stored_bytes.positive?
    elsif base_is_chunked && value.bytesize > base_bytes && base_digest.present? &&
          Digest::SHA256.hexdigest(value.byteslice(0, base_bytes)) == base_digest
      append_transcript_bytes(value.byteslice(base_bytes, value.bytesize - base_bytes))
    elsif base_is_chunked && value.bytesize == base_bytes &&
          base_digest.present? && Digest::SHA256.hexdigest(value) == base_digest
      # Byte-identical to what is stored. Every poll that finds nothing new lands
      # here, so it must not touch the chunk table.
    else
      replace_transcript_chunks(value, base_bytes: stored_bytes, base_is_chunked: stored_bytes.positive?)
    end

    @chunked_transcript_text = value
    # The association's cached rows describe the chunk set as it was before this
    # append; leave them and the next `transcript_chunks` read is a lie.
    transcript_chunks.reset
    remove_instance_variable(:@staged_transcript)
  end

  # The only path that destroys stored transcript bytes. Rare by construction — a
  # rewrite that is not an extension means a carryover re-attachment, a recovery
  # merge, or a fork's truncation — and loud, because "the transcript got shorter
  # and nobody noticed" is the failure `transcript_regression?` exists to catch and
  # this is where it would happen.
  def replace_transcript_chunks(value, base_bytes:, base_is_chunked:)
    if base_is_chunked && value.bytesize < base_bytes
      Rails.logger.warn(
        "[ChunkedTranscript] session #{id}: replacing stored transcript with a shorter one " \
        "(#{base_bytes} bytes -> #{value.bytesize} bytes)"
      )
    end

    SessionTranscriptChunk.where(session_id: id).delete_all
    append_transcript_bytes(value)
  end

  # Append +delta+ to the end of the chunk sequence, topping up the open tail chunk
  # first and cutting new chunks at line breaks.
  def append_transcript_bytes(delta)
    remaining = delta.dup.force_encoding(Encoding::BINARY)
    last = SessionTranscriptChunk.where(session_id: id).order(seq: :desc).first
    seq = last&.seq || -1

    if last&.open?
      room = [ SessionTranscriptChunk::TARGET_BYTES - last.byte_size, 0 ].max
      taken = SessionTranscriptChunk.split_point(remaining, room)
      merged = last.content.dup.force_encoding(Encoding::BINARY) + remaining.byteslice(0, taken)
      merged.force_encoding(Encoding::UTF_8)
      last.update!(
        content: merged,
        byte_size: merged.bytesize,
        line_count: SessionTranscriptChunk.line_count_for(merged)
      )
      remaining = remaining.byteslice(taken, remaining.bytesize - taken).to_s
    end

    rows = SessionTranscriptChunk.rows_for(session_id: id, content: remaining, first_seq: seq + 1)
    SessionTranscriptChunk.insert_all!(rows) if rows.any?
  end
end
