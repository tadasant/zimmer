# frozen_string_literal: true

# Phase 1 of moving `sessions.transcript` out of the row and into an append-only
# chunk table (#110).
#
# WHY: the whole JSONL conversation lives in one column, so every transcript poll
# — roughly every five seconds, for the whole life of a session — rewrites all of
# it. Postgres cannot update a TOASTed value in place: `UPDATE sessions SET
# transcript = …` writes a new tuple, re-compresses and re-stores the entire
# document, and WALs it. The cost of recording ten new lines is therefore a
# function of how much the session has already said, which is exactly backwards
# for the long autonomous sessions Zimmer exists to run.
#
# WHY A ROWS TABLE AND NOT THE OTHER TWO OPTIONS
#
#   * `UPDATE … SET transcript = transcript || $tail` looks like an append and is
#     not one. The concatenation produces a brand-new datum that is re-TOASTed and
#     re-WALed whole, so it buys nothing at all — it just hides the rewrite behind
#     an operator that reads like an append.
#   * Object storage moves the bytes off the box, but it puts a network round trip
#     and a second failure mode in front of the UI's most-read value, and it needs
#     a credential on a path that today needs none. Rejected for the write problem;
#     it remains the right answer for cold archives (#495), which already exist.
#
# A rows table is the one representation where "append ten lines" costs ten lines.
# Chunks are capped (`SessionTranscriptChunk::TARGET_BYTES`), so a poll rewrites at
# most the open tail chunk instead of the whole conversation, and it makes the
# transcript incrementally READABLE too: line counts, byte sizes and tail reads no
# longer detoast megabytes.
#
# `sessions.transcript` IS NOT DROPPED HERE. Dropping a column in the deploy that
# stops using it strands the old containers kamal-proxy is still serving
# (AGENTS.md, "Dropping a column takes two deploys"). It stays as the pre-backfill
# read fallback — `Session#transcript` prefers it while it is non-NULL — and
# `BackfillSessionTranscriptChunks` NULLs it per row only after verifying the copy
# byte for byte. Phase 2 drops it, together with `transcript_digest`.
class CreateSessionTranscriptChunks < ActiveRecord::Migration[8.0]
  def change
    create_table :session_transcript_chunks do |t|
      t.references :session, null: false, foreign_key: { on_delete: :cascade }, index: false
      # Position in the chunk sequence. Gaps are legal and expected: `seq` only has
      # to order, and a replace-then-append leaves whatever numbering it likes.
      t.integer :seq, null: false
      # A byte-exact slice of the JSONL document. Concatenating every chunk of a
      # session in `seq` order reproduces the transcript exactly — that is the
      # invariant the backfill verifies and `ChunkedTranscript` maintains.
      t.text :content, null: false
      t.integer :byte_size, null: false, default: 0
      t.integer :line_count, null: false, default: 0

      t.timestamps
    end

    # The read path is always "every chunk of one session, in order", and the write
    # path always asks for the last one. One unique index serves both and makes a
    # duplicate `seq` — two rows claiming the same position, i.e. an ambiguous
    # transcript — impossible rather than merely unlikely.
    add_index :session_transcript_chunks, [ :session_id, :seq ], unique: true,
      name: "index_session_transcript_chunks_on_session_and_seq"

    # Denormalised summaries of the chunk set, on the session row.
    #
    # These are not a cache for convenience: `transcript_line_count` is what the
    # regression guard compares, and it was previously computed by detoasting the
    # whole document to count newlines. As columns they are also what makes a
    # transcript write dirty the session row, so `updated_at` still moves when the
    # conversation grows even though the bytes now live elsewhere.
    add_column :sessions, :transcript_byte_size, :integer, null: false, default: 0
    add_column :sessions, :transcript_line_count, :integer, null: false, default: 0
    # SHA-256 of the whole stored transcript. The append fast path needs to know
    # that an incoming transcript EXTENDS the stored one, and comparing digests of
    # the leading `transcript_byte_size` bytes answers that without reading a
    # single chunk back out of the database.
    add_column :sessions, :transcript_digest, :string

    # `TranscriptArchiveJob` scans "every session that has a transcript". That
    # predicate used to be `transcript IS NOT NULL`, served by
    # `index_sessions_on_id_where_transcript_present`; after the backfill it is
    # `transcript_byte_size > 0`, which needs its own partial index. The old index
    # stays until the column it is built on goes, in phase 2.
    add_index :sessions, :id, where: "transcript_byte_size > 0",
      name: "index_sessions_on_id_where_transcript_stored"
  end
end
